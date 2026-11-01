import SwiftUI

/// Panel content: a TUI-style tab strip, the selected question, and a status-line footer.
struct PanelView: View {
    @ObservedObject var store: QuestionStore
    var close: () -> Void
    var resize: (CGSize) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tabs
            if let question = store.selected {
                QuestionView(store: store, question: question, draft: store.draft(for: question), close: close)
                    .id(question.id)
            } else {
                empty
            }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self, of: \.size) { resize($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .font(Theme.mono())
        .foregroundStyle(Theme.text)
        .tint(Theme.secondary)
        .background(Theme.background)
        .overlay(Rectangle().strokeBorder(Theme.border, lineWidth: 1))
        .environment(\.colorScheme, .dark)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            if store.questions.isEmpty {
                Text("opencode")
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 14)
            }
            ForEach(store.questions) { question in
                let active = question.id == store.selected?.id
                Button { store.selectedID = question.id } label: {
                    HStack(spacing: 8) {
                        Text("?")
                            .fontWeight(.bold)
                            .foregroundStyle(active ? Theme.primary : Theme.muted)
                        Text(question.projectName)
                            .fontWeight(active ? .bold : .regular)
                            .foregroundStyle(active ? Theme.text : Theme.muted)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .frame(maxHeight: .infinity)
                    .background(active ? Theme.panel : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 12)
            if let question = store.selected {
                Text(question.receivedAt, style: .relative)
                    .foregroundStyle(Theme.muted)
                    .padding(.trailing, 14)
            }
        }
        .frame(height: 32)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No questions waiting")
                .fontWeight(.bold)
            HStack(spacing: 8) {
                Text("•").foregroundStyle(store.connection.isConnected ? Theme.success : Theme.error)
                Text(store.connection.label).foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Theme.panel)
    }
}

struct QuestionView: View {
    @ObservedObject var store: QuestionStore
    let question: PendingQuestion
    @ObservedObject var draft: FormDraft
    var close: () -> Void

    @State private var error: String?
    @State private var busy = false
    @State private var fieldsHeight: CGFloat = 0

    /// Field whose options answer to ⌘1–9. Only one, so shortcuts never clash.
    private var shortcutKey: String? {
        draft.visibleFields.first { $0.type == "multiselect" || $0.options?.isEmpty == false }?.key
    }

    /// The form title is usually a generic "Questions" when the fields carry their own titles.
    private var showsFormTitle: Bool {
        !question.form.fields.contains { $0.title != nil && $0.type != "boolean" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                if let title = question.sessionTitle {
                    Text(title)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if showsFormTitle {
                    Text(question.form.title)
                        .fontWeight(.bold)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ScrollView {
                    fields.onGeometryChange(for: CGFloat.self, of: \.size.height) { fieldsHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(max(fieldsHeight, 1), 600))
                if let error {
                    Text("✗ \(error)")
                        .foregroundStyle(Theme.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel)

            footer
        }
        .disabled(busy)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(draft.visibleFields) { field in
                FieldView(
                    field: field,
                    draft: draft,
                    // Booleans use the title as their label; skip titles that repeat the header.
                    showsTitle: field.type != "boolean" && !(showsFormTitle && field.title == question.form.title),
                    shortcuts: field.key == shortcutKey
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 18) {
            FooterButton(key: "esc", label: "later") { close() }
                .keyboardShortcut(.cancelAction)
            FooterButton(key: nil, label: "dismiss", hoverColor: Theme.error) { run { try await store.dismiss(question) } }
                .help("Cancel this question in OpenCode")
            if shortcutKey != nil {
                HStack(spacing: 6) {
                    Text("⌘1-9")
                    Text("pick").foregroundStyle(Theme.muted)
                }
            }
            Spacer()
            SendButton(busy: busy) { run { try await store.submit(question) } }
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .frame(height: 44)
    }

    private func run(_ action: @escaping () async throws -> Void) {
        error = nil
        busy = true
        Task {
            defer { busy = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
}

struct FieldView: View {
    let field: FormField
    @ObservedObject var draft: FormDraft
    var showsTitle: Bool
    var shortcuts: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsTitle, let title = field.title {
                (Text(title).fontWeight(.bold) + Text(field.isRequired ? " *" : "").foregroundColor(Theme.primary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let description = field.description {
                Text(description)
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            control.padding(.top, 6)
        }
    }

    @ViewBuilder
    private var control: some View {
        switch field.type {
        case "string" where field.options?.isEmpty == false:
            options(multiple: false)
        case "multiselect":
            options(multiple: true)
        case "string":
            PromptInput(placeholder: field.placeholder ?? "Type your answer", text: textBinding)
        case "number", "integer":
            PromptInput(placeholder: field.placeholder ?? (field.type == "integer" ? "Whole number" : "Number"), text: textBinding)
        case "boolean":
            let on = draft.resolved(field) == .bool(true)
            OptionRow(marker: on ? "[x]" : "[ ]", label: field.title ?? "Yes", description: nil, selected: on, hint: nil) {
                draft.values[field.key] = .bool(!on)
            }
        case "external":
            if let link = field.url.flatMap(URL.init(string:)) {
                Link(destination: link) {
                    Text("↗ open \(link.host ?? link.absoluteString)")
                        .foregroundStyle(Theme.secondary)
                        .underline()
                }
            }
        default:
            Text("Unsupported field “\(field.type)”, answer in the terminal.")
                .foregroundStyle(Theme.muted)
        }
    }

    private var textBinding: Binding<String> {
        Binding(get: { draft.text[field.key] ?? "" }, set: { draft.text[field.key] = $0 })
    }

    private func options(multiple: Bool) -> some View {
        let options = field.options ?? []
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.element.value) { index, option in
                let selected = draft.isSelected(option.value, in: field)
                let shortcut: Character? = shortcuts && index < 9 ? Character("\(index + 1)") : nil
                OptionRow(
                    marker: multiple ? (selected ? "[x]" : "[ ]") : "\(index + 1).",
                    label: option.label,
                    description: option.description,
                    selected: selected,
                    hint: multiple ? shortcut.map { "⌘\($0)" } : nil
                ) {
                    if multiple { draft.toggle(option.value, in: field) } else { draft.choose(option.value, in: field) }
                }
                .modifier(OptionalShortcut(key: shortcut))
            }
            if field.allowsCustom {
                CustomRow(
                    marker: multiple ? "[+]" : "\(options.count + 1).",
                    selected: multiple ? !(draft.text[field.key] ?? "").isEmpty : draft.customChosen.contains(field.key),
                    text: Binding(
                        get: { draft.text[field.key] ?? "" },
                        set: { value in
                            draft.text[field.key] = value
                            if !multiple, !value.isEmpty { draft.chooseCustom(in: field) }
                        }
                    ),
                    onFocus: { if !multiple { draft.chooseCustom(in: field) } }
                )
            }
        }
    }
}

/// Row with a left accent bar when selected, like the TUI's prompt box.
private struct RowChrome: ViewModifier {
    let selected: Bool
    let hovering: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected || hovering ? Theme.element : .clear)
            .overlay(alignment: .leading) {
                Rectangle().fill(selected ? Theme.secondary : .clear).frame(width: 2)
            }
            .contentShape(Rectangle())
    }
}

struct OptionRow: View {
    let marker: String
    let label: String
    let description: String?
    let selected: Bool
    let hint: String?
    let action: () -> Void

    @State private var hovering = false

    private static let recommended = "(Recommended)"

    var body: some View {
        let isRecommended = label.hasSuffix(Self.recommended)
        let title = isRecommended ? String(label.dropLast(Self.recommended.count)).trimmingCharacters(in: .whitespaces) : label

        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(marker)
                    .foregroundStyle(selected ? Theme.primary : Theme.muted)
                    .frame(width: 28, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(title)
                            .fontWeight(selected ? .bold : .regular)
                            .foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if isRecommended {
                            Text("recommended")
                                .font(Theme.mono(.bold, size: 11))
                                .foregroundStyle(Theme.background)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.primary)
                        }
                    }
                    if let description {
                        Text(description)
                            .foregroundStyle(Theme.muted)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if let hint {
                    Text(hint).foregroundStyle(Theme.muted)
                }
            }
            .modifier(RowChrome(selected: selected, hovering: hovering))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// "Type your own answer" row; picking it is the same as typing into it.
struct CustomRow: View {
    let marker: String
    let selected: Bool
    @Binding var text: String
    var onFocus: () -> Void

    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(marker)
                .foregroundStyle(selected ? Theme.primary : Theme.muted)
                .frame(width: 28, alignment: .leading)
            TextField("", text: $text, prompt: Text("Type your own answer").foregroundStyle(Theme.muted), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focused)
        }
        .modifier(RowChrome(selected: selected || focused, hovering: hovering))
        .onHover { hovering = $0 }
        .onTapGesture { focused = true }
        .onChange(of: focused) { _, isFocused in if isFocused { onFocus() } }
    }
}

/// Free-text input styled like the TUI prompt box.
struct PromptInput: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.muted), axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...8)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.element)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.secondary).frame(width: 2) }
    }
}

struct FooterButton: View {
    let key: String?
    let label: String
    var hoverColor: Color = Theme.text
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let key { Text(key).foregroundStyle(Theme.text) }
                Text(label).foregroundStyle(hovering ? hoverColor : Theme.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct SendButton: View {
    let busy: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(busy ? "sending…" : "send").fontWeight(.bold)
                Text("⌘↵")
            }
            .foregroundStyle(Theme.background)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(hovering ? Theme.text : Theme.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct OptionalShortcut: ViewModifier {
    let key: Character?
    func body(content: Content) -> some View {
        if let key { content.keyboardShortcut(KeyEquivalent(key), modifiers: .command) } else { content }
    }
}
