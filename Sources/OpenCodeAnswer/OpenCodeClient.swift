import Foundation

/// Registration written by the OpenCode background service (`opencode serve --service`).
struct ServiceInfo: Decodable, Equatable {
    let url: URL
    let password: String
    let version: String?

    static var fileURL: URL {
        let env = ProcessInfo.processInfo.environment
        let state = env["XDG_STATE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
        return state.appendingPathComponent("opencode/service.json")
    }

    static func load() throws -> ServiceInfo {
        try JSONDecoder().decode(ServiceInfo.self, from: Data(contentsOf: fileURL))
    }
}

struct APIError: LocalizedError {
    let status: Int
    let message: String
    /// OpenCode's error type, e.g. `SessionNotFoundError`.
    var tag: String? = nil
    var errorDescription: String? { message }

    /// The question no longer exists or was already answered, so there is nothing left to do.
    var questionIsGone: Bool {
        ["SessionNotFoundError", "FormNotFoundError", "FormAlreadySettledError"].contains(tag ?? "")
    }
}

/// One decoded server-sent event from `/api/event`.
struct ServerEvent {
    let type: String
    let directory: String?
    let data: [String: Any]
    let raw: Data
}

final class OpenCodeClient: @unchecked Sendable {
    let service: ServiceInfo
    private let session: URLSession
    private let streamSession: URLSession

    init(service: ServiceInfo) {
        self.service = service
        session = URLSession(configuration: .ephemeral)
        let streamConfig = URLSessionConfiguration.ephemeral
        streamConfig.timeoutIntervalForRequest = 300
        streamConfig.timeoutIntervalForResource = .infinity
        streamSession = URLSession(configuration: streamConfig)
    }

    private var authorization: String {
        "Basic " + Data("opencode:\(service.password)".utf8).base64EncodedString()
    }

    private func request(_ method: String, _ path: String, body: Any? = nil) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: service.url) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = json?["message"] as? String ?? String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            throw APIError(status: status, message: message, tag: json?["_tag"] as? String)
        }
        return data
    }

    private struct Envelope<T: Decodable>: Decodable { let data: T }

    func activeSessionIDs() async throws -> [String] {
        let data = try await send(request("GET", "/api/session/active"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return Array((json?["data"] as? [String: Any] ?? [:]).keys)
    }

    func forms(sessionID: String) async throws -> [FormInfo] {
        let data = try await send(request("GET", "/api/session/\(sessionID)/form"))
        return try JSONDecoder().decode(Envelope<[FormInfo]>.self, from: data).data
    }

    /// Returns the session's title and directory.
    func sessionInfo(_ sessionID: String) async throws -> (title: String?, directory: String?) {
        let data = try await send(request("GET", "/api/session/\(sessionID)"))
        let json = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [String: Any]
        let location = json?["location"] as? [String: Any]
        return (json?["title"] as? String, location?["directory"] as? String)
    }

    func reply(form: FormInfo, answer: [String: Any]) async throws {
        _ = try await send(request("POST", "/api/session/\(form.sessionID)/form/\(form.id)/reply", body: ["answer": answer]))
    }

    func cancel(form: FormInfo) async throws {
        _ = try await send(request("DELETE", "/api/session/\(form.sessionID)/form/\(form.id)"))
    }

    /// Streams form events until the connection drops. `server.connected` is always delivered.
    func events() -> AsyncThrowingStream<ServerEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var components = URLComponents(url: service.url.appendingPathComponent("api/event"), resolvingAgainstBaseURL: false)!
                    components.queryItems = ["form.created", "form.replied", "form.cancelled", "session.deleted"].map { URLQueryItem(name: "types", value: $0) }
                    var req = URLRequest(url: components.url!)
                    req.setValue(authorization, forHTTPHeaderField: "Authorization")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    let (bytes, response) = try await streamSession.bytes(for: req)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else { throw APIError(status: status, message: "Event stream returned HTTP \(status)") }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                              let type = json["type"] as? String else { continue }
                        let location = json["location"] as? [String: Any]
                        continuation.yield(ServerEvent(
                            type: type,
                            directory: location?["directory"] as? String,
                            data: json["data"] as? [String: Any] ?? [:],
                            raw: payload
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
