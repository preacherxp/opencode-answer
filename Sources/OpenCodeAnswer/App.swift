import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct OpenCodeAnswerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: delegate.store, showPanel: { delegate.showPanel(focus: true) }, showAbout: delegate.showAbout)
        } label: {
            MenuBarLabel(store: delegate.store)
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var store: QuestionStore

    var body: some View {
        if store.questions.isEmpty {
            Image(nsImage: PixelIcon.menuBar(waiting: false))
        } else {
            HStack(spacing: 4) {
                Image(nsImage: PixelIcon.menuBar(waiting: true))
                Text("\(store.questions.count)")
            }
        }
    }
}

/// Menu toggles, stored in UserDefaults. Both start on.
enum Setting: String {
    case popUpPanel, notify

    var isOn: Bool { UserDefaults.standard.object(forKey: rawValue) as? Bool ?? true }
}

struct MenuContent: View {
    @ObservedObject var store: QuestionStore
    var showPanel: () -> Void
    var showAbout: () -> Void

    @AppStorage(Setting.popUpPanel.rawValue) private var popUpPanel = Setting.popUpPanel.isOn
    @AppStorage(Setting.notify.rawValue) private var notify = Setting.notify.isOn
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Text(store.connection.label)

        Divider()

        if store.questions.isEmpty {
            Text("No questions waiting")
        } else {
            ForEach(store.questions) { question in
                Button("\(question.projectName) — \(question.form.title)") {
                    store.selectedID = question.id
                    showPanel()
                }
            }
        }
        Button("Show Panel") { showPanel() }
            .keyboardShortcut("o")

        Divider()

        Toggle("Pop Up Panel for New Questions", isOn: $popUpPanel)
        Toggle("Send Notifications", isOn: $notify)
        Toggle("Launch at Login", isOn: Binding(
            get: { launchAtLogin },
            set: { enabled in
                do {
                    if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    NSLog("Launch at login failed: \(error)")
                }
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        ))

        Divider()

        Button("About OpenCode Answer") { showAbout() }
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = QuestionStore()
    private lazy var panel = QuestionPanel(store: store)
    /// Notifications need an app bundle; a bare `swift run` binary would assert.
    private let notifications: UNUserNotificationCenter? = Bundle.main.bundleIdentifier == nil ? nil : .current()

    func applicationDidFinishLaunching(_ notification: Notification) {
        notifications?.delegate = self
        notifications?.requestAuthorization(options: [.alert, .sound]) { _, _ in }

        store.onNewQuestion = { [weak self] question in self?.announce(question) }
        store.onEmpty = { [weak self] in
            self?.panel.orderOut(nil)
            self?.notifications?.removeAllDeliveredNotifications()
        }
        store.start()
    }

    func showPanel(focus: Bool) {
        panel.present(focus: focus)
    }

    /// The standard About panel: icon, name, version and build from Info.plist, plus the credits below.
    func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: Self.aboutCredits])
    }

    private static var aboutCredits: NSAttributedString {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let style: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centered,
        ]
        let credits = NSMutableAttributedString(string: "Answer OpenCode's questions from the menu bar.\n\n", attributes: style)
        func link(_ title: String, _ url: String) {
            credits.append(NSAttributedString(string: title, attributes: style.merging([.link: URL(string: url)!]) { $1 }))
        }
        link("Source on GitHub", "https://github.com/preacherxp/opencode-answer")
        credits.append(NSAttributedString(string: "  ·  ", attributes: style))
        link("Buy me a coffee", "https://buymeacoffee.com/michal.hachula")
        return credits
    }

    private func announce(_ question: PendingQuestion) {
        if Setting.popUpPanel.isOn {
            if !panel.isVisible { store.selectedID = question.id }
            // Don't take keyboard focus: the user may be typing elsewhere. One click focuses the panel.
            panel.present(focus: false)
        }
        if let notifications, Setting.notify.isOn {
            let content = UNMutableNotificationContent()
            content.title = "OpenCode · \(question.projectName)"
            content.body = question.form.title
            content.sound = .default
            content.userInfo = ["formID": question.id]
            let request = UNNotificationRequest(identifier: question.id, content: content, trigger: nil)
            notifications.add(request)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let formID = response.notification.request.content.userInfo["formID"] as? String
        await MainActor.run {
            if let formID { store.selectedID = formID }
            panel.present(focus: true)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Floating panel that sits above other apps and every Space without activating the app.
final class QuestionPanel: NSPanel {
    init(store: QuestionStore) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
            // Borderless for square, terminal-like corners; Esc and "later" hide it.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        hasShadow = true
        backgroundColor = NSColor(red: 0x0A / 255, green: 0x0A / 255, blue: 0x0A / 255, alpha: 1)
        appearance = NSAppearance(named: .darkAqua)

        // Size is driven one way: SwiftUI reports its ideal size, the panel follows. Letting the
        // hosting view size the window itself loops AppKit's constraint passes and crashes.
        let root = PanelView(
            store: store,
            close: { [weak self] in self?.orderOut(nil) },
            resize: { [weak self] size in self?.fit(size) }
        )
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        contentView = host
    }

    /// Resize to the content, keeping the top-right corner in place and the panel on screen.
    private func fit(_ size: CGSize) {
        let size = CGSize(width: ceil(size.width), height: ceil(size.height))
        guard size.height > 0, size != frame.size else { return }
        var rect = NSRect(x: frame.maxX - size.width, y: frame.maxY - size.height, width: size.width, height: size.height)
        if let visible = screen?.visibleFrame {
            rect.origin.x = min(max(rect.minX, visible.minX), visible.maxX - rect.width)
            rect.origin.y = max(rect.minY, visible.minY)
        }
        setFrame(rect, display: true)
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }


    func present(focus: Bool) {
        if !isVisible {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                setFrameTopLeftPoint(NSPoint(x: visible.maxX - frame.width - 12, y: visible.maxY - 8))
            }
        }
        orderFrontRegardless()
        if focus {
            NSApp.activate()
            makeKey()
        }
    }
}
