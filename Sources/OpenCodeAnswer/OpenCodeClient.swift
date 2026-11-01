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

struct Location: Decodable {
    let directory: String?
}

/// One event from `/api/event`, decoded into the cases the app reacts to.
enum ServerEvent: Decodable {
    case connected
    case formCreated(FormInfo, directory: String?)
    /// The form was replied to or cancelled, here or in the terminal.
    case formSettled(id: String)
    case sessionDeleted(sessionID: String)
    case other

    private enum Keys: String, CodingKey { case type, location, data }
    private struct Created: Decodable { let form: FormInfo }
    private struct Settled: Decodable { let id: String }
    private struct Deleted: Decodable { let sessionID: String }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "server.connected":
            self = .connected
        case "form.created":
            let location = try? c.decodeIfPresent(Location.self, forKey: .location)
            self = .formCreated(try c.decode(Created.self, forKey: .data).form, directory: location?.directory)
        case "form.replied", "form.cancelled":
            self = .formSettled(id: try c.decode(Settled.self, forKey: .data).id)
        case "session.deleted":
            self = .sessionDeleted(sessionID: try c.decode(Deleted.self, forKey: .data).sessionID)
        default:
            self = .other
        }
    }
}

struct SessionInfo: Decodable {
    let title: String?
    let location: Location?
}

final class OpenCodeClient: @unchecked Sendable {
    let service: ServiceInfo
    private let session = URLSession(configuration: .ephemeral)

    init(service: ServiceInfo) {
        self.service = service
    }

    private var authorization: String {
        "Basic " + Data("opencode:\(service.password)".utf8).base64EncodedString()
    }

    private func request(_ method: String, _ path: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: service.url) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(authorization, forHTTPHeaderField: "Authorization")
        return req
    }

    private struct ErrorBody: Decodable {
        let message: String?
        let tag: String?
        enum CodingKeys: String, CodingKey { case message, tag = "_tag" }
    }

    @discardableResult
    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            let message = body?.message ?? String(data: data, encoding: .utf8) ?? "HTTP \(status)"
            throw APIError(status: status, message: message, tag: body?.tag)
        }
        return data
    }

    private struct Envelope<T: Decodable>: Decodable { let data: T }

    /// GETs a path and unwraps the `data` envelope.
    private func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        try JSONDecoder().decode(Envelope<T>.self, from: await send(request("GET", path))).data
    }

    /// A JSON object whose contents don't matter.
    private struct Ignored: Decodable {}

    func activeSessionIDs() async throws -> [String] {
        Array(try await get("/api/session/active", as: [String: Ignored].self).keys)
    }

    func forms(sessionID: String) async throws -> [FormInfo] {
        try await get("/api/session/\(sessionID)/form")
    }

    func sessionInfo(_ sessionID: String) async throws -> SessionInfo {
        try await get("/api/session/\(sessionID)")
    }

    func reply(form: FormInfo, answer: [String: FormValue]) async throws {
        var req = try request("POST", "/api/session/\(form.sessionID)/form/\(form.id)/reply")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["answer": answer])
        try await send(req)
    }

    func cancel(form: FormInfo) async throws {
        try await send(request("DELETE", "/api/session/\(form.sessionID)/form/\(form.id)"))
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
                    // Idle timeout between events. The session's 7-day resource limit only forces a reconnect.
                    req.timeoutInterval = 300

                    let (bytes, response) = try await session.bytes(for: req)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard status == 200 else { throw APIError(status: status, message: "Event stream returned HTTP \(status)") }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                        // Events the app can't decode are skipped, like unknown event types.
                        if let event = try? JSONDecoder().decode(ServerEvent.self, from: payload) {
                            continuation.yield(event)
                        }
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
