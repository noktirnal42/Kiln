import Foundation
import AxiomCore

/// Hands a function or address to lldb. Planning is pure; running a plan launches the target under the debugger and therefore needs
/// the analyst's explicit approval (the GUI asks, and the agent tool is an execute-level tool).
public struct REDebugPlan: Sendable, Equatable {
    public enum Mode: String, Sendable { case launch, attach, inspect }
    public var mode: Mode
    public var program: URL
    public var arguments: [String]
    public var pid: Int32?
    public var breakpoints: [UInt64]
    public var commands: [String]

    /// The full lldb batch, one command per line, as the analyst will see it before approving.
    public var script: String { commands.joined(separator: "\n") }
    public var summary: String {
        switch mode {
        case .launch: "Launch \(program.lastPathComponent) under lldb, stopped at its entry point, with \(breakpoints.count) breakpoint(s)"
        case .attach: "Attach lldb to process \(pid ?? 0) with \(breakpoints.count) breakpoint(s)"
        case .inspect: "Load \(program.lastPathComponent) into lldb without running it and resolve \(breakpoints.count) breakpoint(s)"
        }
    }
}

public enum REDebugLink {
    public static var lldbAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") && ((try? ProcessRunner.run("/usr/bin/xcrun", ["--find", "lldb"], timeout: 10)) != nil) }

    /// `breakpoints` are addresses as the listing shows them (file addresses). With a module name lldb treats them as such, so ASLR does not matter.
    public static func plan(mode: REDebugPlan.Mode, program: URL, breakpoints: [UInt64], arguments: [String] = [], pid: Int32? = nil, architecture: String? = nil) throws -> REDebugPlan {
        guard FileManager.default.fileExists(atPath: program.path) || mode == .attach else { throw REError.invalidArgument("program not found: \(program.path)") }
        guard breakpoints.count <= 64 else { throw REError.invalidArgument("at most 64 breakpoints") }
        if mode == .attach { guard let pid, pid > 1 else { throw REError.invalidArgument("attach needs a process id") } }
        let module = program.lastPathComponent
        var commands: [String] = []
        if mode == .attach { commands.append("process attach --pid \(pid ?? 0)") }
        else { commands.append("target create " + (architecture.map { "--arch \($0) " } ?? "") + quote(program.path)) }
        for address in breakpoints { commands.append("breakpoint set --shlib \(quote(module)) --address 0x\(REListing.hex(address))") }
        commands.append("breakpoint list")
        if mode == .launch {
            commands.append("process launch --stop-at-entry" + (arguments.isEmpty ? "" : " -- " + arguments.map(quote).joined(separator: " ")))
            commands.append("register read")
            commands.append("thread backtrace")
        }
        return REDebugPlan(mode: mode, program: program, arguments: arguments, pid: pid, breakpoints: breakpoints, commands: commands)
    }

    /// Runs the plan in lldb's batch mode and returns its output. The process is killed at the end of the batch; a launch is
    /// bounded by `timeout`. Callers must have the analyst's approval.
    public static func run(_ plan: REDebugPlan, timeout: TimeInterval = 60) throws -> String {
        var arguments = ["lldb", "--no-lldbinit", "--batch"]
        for command in plan.commands { arguments += ["-o", command] }
        if plan.mode != .inspect { arguments += ["-o", "process kill"] }
        return try ProcessRunner.run("/usr/bin/xcrun", arguments, timeout: timeout)
    }

    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
