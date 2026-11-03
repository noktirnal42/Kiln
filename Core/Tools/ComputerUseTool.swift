import AppKit
import ApplicationServices
import Foundation

/// Native, explicitly enabled Accessibility control. Indices are valid only for the latest snapshot of one app.
@MainActor
final class ComputerUseService {
    static let shared = ComputerUseService()
    private var elements: [AXUIElement] = []
    private var snapshotPID: pid_t?
    private var maxElements = 400
    private var maxDepth = 14

    func run(action: String, app: String?, index: Int?, text: String?, query: String? = nil, maxElements limit: Int? = nil, maxDepth depth: Int? = nil, key: String? = nil) -> String {
        guard UserDefaults.standard.bool(forKey: "computerUse.enabled") else { return "Computer use is off. Enable it in Kiln Settings first." }
        if action == "list_apps" {
            return NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { item in
                guard let name = item.localizedName else { return nil }
                return "\(name) (\(item.bundleIdentifier ?? "no bundle ID"))"
            }.sorted().joined(separator: "\n")
        }
        guard AXIsProcessTrusted() else { return "This copy of Kiln (\(Bundle.main.bundlePath)) is not trusted for Accessibility. Open Kiln Settings and press Request Accessibility access. If System Settings already lists Kiln as ON, that entry belongs to a different build of Kiln (an earlier or development copy): remove it with the minus button, add this copy with the plus button, switch it on, and relaunch Kiln. Then retry." }
        guard let name = app, !name.isEmpty else { return "Specify a running application name or bundle ID." }
        if action == "open_app" {
            // Launching an app is how a person would start reading their messages; it does not click anything inside it.
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name)
                    ?? NSWorkspace.shared.runningApplications.first(where: { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame })?.bundleURL
                    ?? Self.applicationURL(named: name) else { return "Could not find an application called \(name)." }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false   // leave the person's front window alone
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return "Opened \(url.deletingPathExtension().lastPathComponent) in the background. Wait a moment, then inspect or read it."
        }
        guard let target = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == name || $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }) else { return "Application is not running: \(name)." }
        guard target.bundleIdentifier != Bundle.main.bundleIdentifier, target.bundleIdentifier != "com.apple.systempreferences" else { return "Kiln and System Settings cannot be controlled by this tool." }
        switch action {
        case "inspect":
            maxElements = min(max(limit ?? 400, 50), 2500)
            maxDepth = min(max(depth ?? 14, 3), 30)
            elements = []; snapshotPID = target.processIdentifier
            let root = AXUIElementCreateApplication(target.processIdentifier)
            var lines: [String] = []
            appendTree(root, depth: 0, lines: &lines)
            if let query, !query.isEmpty {
                let matching = lines.filter { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
                return matching.isEmpty ? "No element in the first \(elements.count) matched \"\(query)\". Try a larger max_elements or max_depth." : matching.joined(separator: "\n")
            }
            if elements.count >= maxElements { lines.append("[stopped at \(maxElements) elements: use query, or raise max_elements, to see more]") }
            return lines.isEmpty ? "No accessible elements were exposed by \(name)." : lines.joined(separator: "\n")
        case "read":
            // Just the words on screen, in reading order, without indices: how to read a conversation or a list.
            maxElements = 2500; maxDepth = 30
            elements = []
            var seen = Set<String>()
            var lines: [String] = []
            readText(AXUIElementCreateApplication(target.processIdentifier), depth: 0, seen: &seen, lines: &lines)
            let text = lines.joined(separator: "\n")
            return text.isEmpty ? "No readable text was exposed by \(name). It may be minimized, locked or showing nothing yet." : String(text.prefix(30_000))
        case "activate":
            target.activate()
            return "Brought \(name) to the front. Inspect it again before using element indices."
        case "focus":
            guard snapshotPID == target.processIdentifier, let index, elements.indices.contains(index) else { return "Inspect this app again before using an element index." }
            let element = elements[index]
            let role = attribute(element, kAXRoleAttribute as String) as? String ?? ""
            guard role != "AXSecureTextField" else { return "Secure text fields cannot be focused by this tool." }
            let result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            return result == .success ? "Focused element \(index). Use type_text or key next." : "The element did not accept focus (Accessibility error \(result.rawValue)). Try press on it first."
        case "type_text":
            guard let text, !text.isEmpty else { return "Specify text to type." }
            guard text.count <= 500 else { return "Text is longer than 500 characters; type it in parts." }
            if let refusal = Self.refuseIfSecureFocus(in: target) { return refusal }
            target.activate()
            Self.pause(0.25)
            Self.typeUnicode(text, pid: target.processIdentifier)
            return "Typed \(text.count) characters into \(name). Use read or inspect to confirm they appear before sending or pressing Return."
        case "key":
            guard let key, let combo = Self.parseKey(key) else { return "Unsupported key. Allowed: return, enter, tab, space, delete, escape, left, right, up, down, pageup, pagedown, home, end, cmd+return, cmd+a, cmd+f, cmd+l." }
            if let refusal = Self.refuseIfSecureFocus(in: target) { return refusal }
            target.activate()
            Self.pause(0.25)
            Self.pressKey(combo, pid: target.processIdentifier)
            return "Pressed \(key) in \(name). Use read to confirm what changed; do not assume it worked."
        case "press", "set_value":
            guard snapshotPID == target.processIdentifier, let index, elements.indices.contains(index) else { return "Inspect this app again before using an element index." }
            let element = elements[index]
            elements = []; snapshotPID = nil
            let role = attribute(element, kAXRoleAttribute as String) as? String ?? ""
            let subrole = attribute(element, kAXSubroleAttribute as String) as? String ?? ""
            guard role != "AXSecureTextField", subrole != "AXSecureTextField" else { return "Secure text fields cannot be changed by this tool." }
            if action == "press" {
                let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
                return result == .success ? "Pressed element \(index). Inspect the app again before another action." : "The element did not accept a press (Accessibility error \(result.rawValue))."
            }
            guard let text else { return "Specify text for set_value." }
            let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
            return result == .success ? "Updated element \(index). Inspect the app again before another action." : "The element did not accept a value (Accessibility error \(result.rawValue))."
        default: return "Unknown action. Use list_apps, open_app, activate, focus, type_text, key, read, inspect, press, or set_value."
        }
    }

    // MARK: Keyboard

    struct KeyCombo: Equatable { let code: CGKeyCode; let flags: CGEventFlags }

    /// Only plain navigation and confirmation keys, and a few command shortcuts. Nothing that quits, closes, hides or switches apps.
    nonisolated static func parseKey(_ text: String) -> KeyCombo? {
        let name = text.lowercased().replacingOccurrences(of: " ", with: "")
        let codes: [String: CGKeyCode] = ["return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51, "escape": 53, "left": 123, "right": 124,
                                          "down": 125, "up": 126, "pageup": 116, "pagedown": 121, "home": 115, "end": 119]
        if let code = codes[name] { return KeyCombo(code: code, flags: []) }
        let combos: [String: KeyCombo] = ["cmd+return": KeyCombo(code: 36, flags: .maskCommand), "cmd+a": KeyCombo(code: 0, flags: .maskCommand),
                                          "cmd+f": KeyCombo(code: 3, flags: .maskCommand), "cmd+l": KeyCombo(code: 37, flags: .maskCommand)]
        return combos[name]
    }

    private static func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    /// Typing and key presses go to whatever has focus in the app, so refuse when that is a password field.
    private static func refuseIfSecureFocus(in target: NSRunningApplication) -> String? {
        let appElement = AXUIElementCreateApplication(target.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let focused else { return nil }
        let element = focused as! AXUIElement
        var role: CFTypeRef?, subrole: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        if (role as? String) == "AXSecureTextField" || (subrole as? String) == "AXSecureTextField" {
            return "The focused field is a secure (password) field; this tool does not type into it."
        }
        return nil
    }

    private static func typeUnicode(_ text: String, pid: pid_t) {
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let end = min(index + 16, units.count)
            var chunk = Array(units[index..<end])
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                event.postToPid(pid)
            }
            index = end
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private static func pressKey(_ combo: KeyCombo, pid: pid_t) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: combo.code, keyDown: down) else { continue }
            event.flags = combo.flags
            event.postToPid(pid)
        }
    }

    private static func applicationURL(named name: String) -> URL? {
        for directory in ["/Applications", "/System/Applications", "/System/Applications/Utilities"] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name.hasSuffix(".app") ? name : name + ".app")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Collects the text an app shows: values, titles and descriptions of text-like elements, skipping secure fields and repeats.
    private func readText(_ element: AXUIElement, depth: Int, seen: inout Set<String>, lines: inout [String]) {
        guard depth <= maxDepth, lines.count < 4000 else { return }
        let role = attribute(element, kAXRoleAttribute as String) as? String ?? ""
        let subrole = attribute(element, kAXSubroleAttribute as String) as? String ?? ""
        if role != "AXSecureTextField", subrole != "AXSecureTextField" {
            let candidates = [attribute(element, kAXValueAttribute as String) as? String,
                              attribute(element, kAXTitleAttribute as String) as? String,
                              attribute(element, kAXDescriptionAttribute as String) as? String]
            for case let text? in candidates where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let line = String(text.prefix(1000))
                if seen.insert(line).inserted { lines.append(line) }
            }
        }
        if let children = attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] {
            for child in children { readText(child, depth: depth + 1, seen: &seen, lines: &lines) }
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private func appendTree(_ element: AXUIElement, depth: Int, lines: inout [String]) {
        guard elements.count < maxElements, depth <= maxDepth else { return }
        let role = attribute(element, kAXRoleAttribute as String) as? String ?? "AXUnknown"
        let title = (attribute(element, kAXTitleAttribute as String) as? String) ?? (attribute(element, kAXDescriptionAttribute as String) as? String) ?? ""
        let subrole = attribute(element, kAXSubroleAttribute as String) as? String ?? ""
        let value = (role == "AXSecureTextField" || subrole == "AXSecureTextField") ? "[secure]" : (attribute(element, kAXValueAttribute as String) as? String ?? "")
        let index = elements.count; elements.append(element)
        let detail = [title, value].filter { !$0.isEmpty }.joined(separator: " · ")
        lines.append("\(String(repeating: "  ", count: depth))\(index) \(role) \(String(detail.prefix(500)))")
        if let children = attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] {
            for child in children { appendTree(child, depth: depth + 1, lines: &lines) }
        }
    }
}

public struct ComputerUseTool: ToolExecuting {
    public init() {}
    public var spec: ToolSpec { ToolSpec(name: "computer_use", summary: "Inspect and control a running Mac app using Accessibility", detail: "Enable Computer use in Kiln Settings and grant Accessibility access. Inspect an app before pressing or setting an element. Every call requires approval; secure fields and Kiln itself are blocked. Actions: list_apps, open_app (launch in the background), activate (bring to front), focus (give a numbered field keyboard focus), type_text (real keystrokes), key (return, tab, escape, arrows, cmd+return), read (the text an app shows, in order: use this for messages, mail, notes, calendars), inspect (a numbered element tree, optionally filtered by query and sized by max_elements and max_depth), press, set_value. To read Messages: open_app Messages, press a conversation from inspect (query the contact name), then read. To SEND a message: open the conversation, inspect to find the compose field, focus it, type_text the message, key return, then read the conversation to confirm the message appears. Never use set_value for chat apps (it does not register as typing), never press unrelated numbered elements hoping one is Send, and never say a message was sent until read shows it.", parameters: [ToolParam(name: "action", description: "list_apps, open_app, activate, focus, type_text, key, read, inspect, press, or set_value"), ToolParam(name: "app", description: "App name or bundle ID, for example Messages or com.apple.MobileSMS", required: false), ToolParam(name: "element_index", type: "integer", description: "Index from the latest inspect", required: false), ToolParam(name: "text", description: "Value to set", required: false), ToolParam(name: "query", description: "inspect only: keep lines containing this text", required: false), ToolParam(name: "max_elements", type: "integer", description: "inspect only: how many elements to walk (default 400, up to 2500)", required: false), ToolParam(name: "max_depth", type: "integer", description: "inspect only: how deep (default 14, up to 30)", required: false), ToolParam(name: "key", description: "key action only: return, enter, tab, space, delete, escape, left, right, up, down, pageup, pagedown, home, end, cmd+return, cmd+a, cmd+f, cmd+l", required: false)], permission: .admin) }
    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        struct Args: Decodable { let action: String; let app: String?; let element_index: Int?; let text: String?; let query: String?; let max_elements: Int?; let max_depth: Int?; let key: String? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        return await ComputerUseService.shared.run(action: args.action, app: args.app, index: args.element_index, text: args.text, query: args.query, maxElements: args.max_elements, maxDepth: args.max_depth, key: args.key)
    }
}
