import AppKit
import ApplicationServices
import Foundation

/// Native, explicitly enabled Accessibility control. Indices are valid only for the latest snapshot of one app.
@MainActor
final class ComputerUseService {
    static let shared = ComputerUseService()
    private var elements: [AXUIElement] = []
    private var snapshotPID: pid_t?
    private let maxElements = 400

    func run(action: String, app: String?, index: Int?, text: String?) -> String {
        guard UserDefaults.standard.bool(forKey: "computerUse.enabled") else { return "Computer use is off. Enable it in Kiln Settings first." }
        if action == "list_apps" {
            return NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { item in
                guard let name = item.localizedName else { return nil }
                return "\(name) (\(item.bundleIdentifier ?? "no bundle ID"))"
            }.sorted().joined(separator: "\n")
        }
        guard AXIsProcessTrusted() else { return "Kiln needs macOS Accessibility access. Enable Kiln in System Settings → Privacy & Security → Accessibility, then retry." }
        guard let name = app, !name.isEmpty else { return "Specify a running application name or bundle ID." }
        guard let target = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == name || $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }) else { return "Application is not running: \(name)." }
        guard target.bundleIdentifier != Bundle.main.bundleIdentifier, target.bundleIdentifier != "com.apple.systempreferences" else { return "Kiln and System Settings cannot be controlled by this tool." }
        switch action {
        case "inspect":
            elements = []; snapshotPID = target.processIdentifier
            let root = AXUIElementCreateApplication(target.processIdentifier)
            var lines: [String] = []
            appendTree(root, depth: 0, lines: &lines)
            return lines.isEmpty ? "No accessible elements were exposed by \(name)." : lines.joined(separator: "\n")
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
        default: return "Unknown action. Use list_apps, inspect, press, or set_value."
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private func appendTree(_ element: AXUIElement, depth: Int, lines: inout [String]) {
        guard elements.count < maxElements, depth <= 14 else { return }
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
    public var spec: ToolSpec { ToolSpec(name: "computer_use", summary: "Inspect and control a running Mac app using Accessibility", detail: "Enable Computer use in Kiln Settings and grant Accessibility access. Inspect an app before pressing or setting an element. Every call requires approval; secure fields and Kiln itself are blocked. Actions: list_apps, inspect, press, set_value.", parameters: [ToolParam(name: "action", description: "list_apps, inspect, press, or set_value"), ToolParam(name: "app", description: "Running app name or bundle ID", required: false), ToolParam(name: "element_index", type: "integer", description: "Index from the latest inspect", required: false), ToolParam(name: "text", description: "Value to set", required: false)], permission: .admin) }
    public func execute(argumentsJSON: String, context: ToolExecutionContext) async throws -> String {
        struct Args: Decodable { let action: String; let app: String?; let element_index: Int?; let text: String? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        return await ComputerUseService.shared.run(action: args.action, app: args.app, index: args.element_index, text: args.text)
    }
}
