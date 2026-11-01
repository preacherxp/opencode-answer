import Foundation
import SwiftUI

enum ConnectionState: Equatable {
    case connecting
    case connected(version: String?)
    case disconnected(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .connecting: return "Connecting to OpenCode…"
        case .connected(let version): return "Connected" + (version.map { " · v\($0)" } ?? "")
        case .disconnected(let reason): return "Disconnected · \(reason)"
        }
    }
}

@MainActor
final class QuestionStore: ObservableObject {
    @Published private(set) var questions: [PendingQuestion] = []
    @Published private(set) var connection: ConnectionState = .connecting
    @Published var selectedID: String?

    /// Called when a question arrives that wasn't known before.
    var onNewQuestion: ((PendingQuestion) -> Void)?
    /// Called when the last pending question goes away.
    var onEmpty: (() -> Void)?

    private var drafts: [String: FormDraft] = [:]
    private var client: OpenCodeClient?
    private var loop: Task<Void, Never>?

    var selected: PendingQuestion? {
        questions.first { $0.id == selectedID } ?? questions.first
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { await run() }
    }

    func draft(for question: PendingQuestion) -> FormDraft {
        if let draft = drafts[question.id] { return draft }
        let draft = FormDraft(form: question.form)
        drafts[question.id] = draft
        return draft
    }

    // MARK: Connection loop

    private func run() async {
        var delay: UInt64 = 1
        while !Task.isCancelled {
            do {
                // Re-read every attempt: the service picks a new port and password on restart.
                let service = try ServiceInfo.load()
                let client = OpenCodeClient(service: service)
                self.client = client
                connection = .connecting

                for try await event in client.events() {
                    delay = 1
                    await handle(event, client: client)
                }
                connection = .disconnected("stream closed")
            } catch {
                connection = .disconnected(Self.describe(error))
            }
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            delay = min(delay * 2, 15)
        }
    }

    private static func describe(_ error: Error) -> String {
        if (error as NSError).domain == NSCocoaErrorDomain { return "service not running" }
        if let error = error as? URLError {
            switch error.code {
            case .cannotConnectToHost, .networkConnectionLost: return "service not reachable"
            case .timedOut: return "timed out"
            default: break
            }
        }
        return error.localizedDescription
    }

    private func handle(_ event: ServerEvent, client: OpenCodeClient) async {
        switch event.type {
        case "server.connected":
            connection = .connected(version: client.service.version)
            await resync(client: client)

        case "form.created":
            guard let raw = event.data["form"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let form = try? JSONDecoder().decode(FormInfo.self, from: data) else { return }
            add(form, directory: event.directory, client: client, announce: true)

        case "form.replied", "form.cancelled":
            if let id = event.data["id"] as? String { remove(id) }

        case "session.deleted":
            // Deleting a session doesn't cancel its forms, so drop them here.
            guard let sessionID = event.data["sessionID"] as? String else { return }
            for question in questions where question.form.sessionID == sessionID { remove(question.id) }

        default:
            break
        }
    }

    /// Rebuilds the pending list from the server, which has no event replay.
    private func resync(client: OpenCodeClient) async {
        guard let sessionIDs = try? await client.activeSessionIDs() else { return }
        var live: [FormInfo] = []
        await withTaskGroup(of: [FormInfo].self) { group in
            for id in sessionIDs {
                group.addTask { (try? await client.forms(sessionID: id)) ?? [] }
            }
            for await forms in group { live += forms }
        }
        let liveIDs = Set(live.map(\.id))
        for question in questions where !liveIDs.contains(question.id) { remove(question.id) }
        for form in live { add(form, directory: nil, client: client, announce: true) }
    }

    private func add(_ form: FormInfo, directory: String?, client: OpenCodeClient, announce: Bool) {
        guard !questions.contains(where: { $0.id == form.id }) else { return }
        let question = PendingQuestion(form: form, directory: directory, sessionTitle: nil, receivedAt: Date())
        questions.append(question)
        if announce { onNewQuestion?(question) }

        Task {
            guard let info = try? await client.sessionInfo(form.sessionID),
                  let index = questions.firstIndex(where: { $0.id == form.id }) else { return }
            questions[index].sessionTitle = info.title
            questions[index].directory = questions[index].directory ?? info.directory
        }
    }

    private func remove(_ id: String) {
        questions.removeAll { $0.id == id }
        drafts[id] = nil
        if selectedID == id { selectedID = questions.first?.id }
        if questions.isEmpty { onEmpty?() }
    }

    // MARK: Actions

    func submit(_ question: PendingQuestion) async throws {
        guard let client else { throw APIError(status: 0, message: "Not connected to OpenCode") }
        let answer = try draft(for: question).answer()
        try await removingIfGone(question) { try await client.reply(form: question.form, answer: answer) }
    }

    func dismiss(_ question: PendingQuestion) async throws {
        guard let client else { throw APIError(status: 0, message: "Not connected to OpenCode") }
        try await removingIfGone(question) { try await client.cancel(form: question.form) }
    }

    /// Runs a request for a question and removes it afterwards, also when the server says it no longer exists.
    private func removingIfGone(_ question: PendingQuestion, _ request: () async throws -> Void) async throws {
        do {
            try await request()
        } catch let error as APIError where error.questionIsGone {
            // Fall through: the session was deleted or the question settled elsewhere.
        }
        remove(question.id)
    }
}
