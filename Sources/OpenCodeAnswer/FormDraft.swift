import Foundation

struct ValidationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Editable answer state for one form. Kept per form so switching between questions keeps input.
@MainActor
final class FormDraft: ObservableObject {
    let form: FormInfo

    /// Selected option values, booleans, and multiselect arrays.
    @Published var values: [String: FormValue] = [:]
    /// Free text: plain string fields, number fields, and "Other" entries.
    @Published var text: [String: String] = [:]
    /// Single-select fields where the "Other" entry is chosen.
    @Published var customChosen: Set<String> = []

    init(form: FormInfo) {
        self.form = form
        for field in form.fields {
            guard let value = field.defaultValue else { continue }
            switch (field.type, value) {
            case ("string", .string(let s)):
                if let options = field.options, !options.isEmpty {
                    if options.contains(where: { $0.value == s }) { values[field.key] = value }
                    else if field.allowsCustom { customChosen.insert(field.key); text[field.key] = s }
                } else {
                    text[field.key] = s
                }
            case ("number", .number(let n)), ("integer", .number(let n)):
                if n.isFinite { text[field.key] = Self.format(n) }
            default:
                values[field.key] = value
            }
        }
    }

    private static func format(_ n: Double) -> String {
        n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
    }

    /// Current value of a field, or nil when it has none.
    func resolved(_ field: FormField) -> FormValue? {
        let typed = text[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch field.type {
        case "string":
            if field.options?.isEmpty == false, !customChosen.contains(field.key) { return values[field.key] }
            return typed.isEmpty ? nil : .string(typed)
        case "number":
            return Double(typed).map(FormValue.number)
        case "integer":
            return Int(typed).map { .number(Double($0)) }
        case "multiselect":
            var items: [String] = []
            if case .array(let selected)? = values[field.key] { items = selected }
            if field.allowsCustom, !typed.isEmpty { items.append(typed) }
            return items.isEmpty ? nil : .array(items)
        case "boolean":
            // The toggle shows "off" until touched, so that's the answer.
            return values[field.key] ?? field.defaultValue ?? .bool(false)
        default:
            return nil
        }
    }

    func isVisible(_ field: FormField) -> Bool {
        if field.hidden == true || field.type == "external" && field.url == nil { return false }
        return (field.when ?? []).allSatisfy { condition in
            guard let other = form.fields.first(where: { $0.key == condition.key }) else { return true }
            let matches = resolved(other)?.matches(condition.value) ?? false
            return condition.op == "neq" ? !matches : matches
        }
    }

    var visibleFields: [FormField] { form.fields.filter(isVisible) }

    func toggle(_ option: String, in field: FormField) {
        var selected: [String] = []
        if case .array(let current)? = values[field.key] { selected = current }
        if let index = selected.firstIndex(of: option) { selected.remove(at: index) }
        else { selected.append(option) }
        values[field.key] = .array(selected)
    }

    func isSelected(_ option: String, in field: FormField) -> Bool {
        if field.type == "multiselect" {
            if case .array(let current)? = values[field.key] { return current.contains(option) }
            return false
        }
        return !customChosen.contains(field.key) && values[field.key] == .string(option)
    }

    func choose(_ option: String, in field: FormField) {
        customChosen.remove(field.key)
        values[field.key] = .string(option)
    }

    func chooseCustom(in field: FormField) {
        customChosen.insert(field.key)
    }

    /// Builds the reply payload, validating what the server would otherwise reject.
    func answer() throws -> [String: Any] {
        var answer: [String: Any] = [:]
        for field in form.fields where field.type != "external" {
            let visible = isVisible(field)
            if !visible && field.hidden != true { continue }

            let raw = text[field.key]?.trimmingCharacters(in: .whitespaces) ?? ""
            if (field.type == "number" || field.type == "integer"), !raw.isEmpty, resolved(field) == nil {
                throw ValidationError(message: "“\(field.title ?? field.key)” needs \(field.type == "integer" ? "a whole number" : "a number").")
            }

            guard let value = resolved(field) ?? (visible ? nil : field.defaultValue) else {
                if field.isRequired && visible {
                    throw ValidationError(message: "“\(field.title ?? field.key)” needs an answer.")
                }
                continue
            }
            if case .array(let items) = value {
                if let min = field.minItems, items.count < min { throw ValidationError(message: "Pick at least \(min) for “\(field.title ?? field.key)”.") }
                if let max = field.maxItems, items.count > max { throw ValidationError(message: "Pick at most \(max) for “\(field.title ?? field.key)”.") }
            }
            switch value {
            case .string(let s): answer[field.key] = s
            case .number(let n): answer[field.key] = field.type == "integer" ? Int(n) as Any : n as Any
            case .bool(let b): answer[field.key] = b
            case .array(let a): answer[field.key] = a
            }
        }
        return answer
    }
}
