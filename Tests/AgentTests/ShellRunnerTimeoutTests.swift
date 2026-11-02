import Foundation
import Testing
@testable import Kiln

struct ShellRunnerTimeoutTests {
    /// A grandchild that keeps the output pipe open used to block the read forever, and reading
    /// `terminationStatus` while the task was still running crashed the app.
    @Test func timeoutReturnsPromptlyEvenWhenAGrandchildHoldsThePipe() async throws {
        let started = Date()
        let result = try await ShellRunner.run(command: "echo started; sleep 30 & wait", cwd: nil, timeout: 1)
        #expect(result.timedOut)
        #expect(result.output.contains("started"))
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func normalCommandReportsItsExitStatus() async throws {
        let result = try await ShellRunner.run(command: "echo hi; exit 3", cwd: nil, timeout: 5)
        #expect(!result.timedOut)
        #expect(result.exitStatus == 3)
        #expect(result.output == "hi")
    }
}
