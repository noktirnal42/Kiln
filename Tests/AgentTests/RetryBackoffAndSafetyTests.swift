import Foundation
import Testing
@testable import Kiln

// MARK: - Retry / backoff (System5's _turn_with_retry, ported)

struct RetryBackoffTests {
    @Test func transient429IsRetriedWithBackoffAndThenSucceeds() async throws {
        let registry = ToolRegistry(tools: [])
        let (center, watcher) = try await makeTestApprovalCenter(autoResolve: .deny)
        defer { watcher.cancel() }
        let orchestrator = AgentOrchestrator(toolRegistry: registry, approvalCenter: center)
        let profile = AgentProfile(name: "c", mode: .askOnly, toolPermissions: ToolPermissionSet(enabledTools: []))

        let chat = ScriptedChat(
            turns: [ScriptedTurn(text: "recovered")],
            failuresBeforeSuccess: 2,
            failureFactory: { ProviderError.rateLimited }
        )
        let (events, error) = await collectRun(
            orchestrator, profile: profile, prompt: "hi",
            backoffUnitSeconds: 0.05,
            chat: chat.factory
        )
        #expect(error == nil)
        let retries = events.compactMap { ev -> (Int, Double, String)? in
            if case .retryScheduled(let attempt, let delay, let reason) = ev { return (attempt, delay, reason) }
            return nil
        }
        #expect(retries.count == 2)
        guard retries.count == 2 else { return }
        #expect(retries[0].0 == 1 && retries[0].1 == 0.05)
        #expect(retries[1].0 == 2 && retries[1].1 == 0.1)
        #expect(retries[0].2.lowercased().contains("rate"), "reason: \(retries[0].2)")
        let finished = events.compactMap { ev -> AgentRunSummary? in if case .finished(let s) = ev { return s }; return nil }
        #expect(finished.count == 1)
        #expect(finished[0].finalText == "recovered")
    }

    @Test func stopDuringBackoffCancelsWithinASecond() async throws {
        let registry = ToolRegistry(tools: [])
        let (center, watcher) = try await makeTestApprovalCenter(autoResolve: .deny)
        defer { watcher.cancel() }
        let orchestrator = AgentOrchestrator(toolRegistry: registry, approvalCenter: center)
        let profile = AgentProfile(name: "c", mode: .askOnly, toolPermissions: ToolPermissionSet(enabledTools: []))

        // Fails forever at the real 1s backoff scale: the full schedule
        // would sleep 1+2+4+8s. Stop pressed at 1.2s must land within a
        // second after that, not after the schedule.
        let chat = ScriptedChat(
            turns: [ScriptedTurn(text: "never")],
            failuresBeforeSuccess: 100,
            failureFactory: { ProviderError.rateLimited }
        )
        let stop = AgentStopFlag()
        let start = Date()
        let runTask = Task {
            await collectRun(
                orchestrator, profile: profile, prompt: "hi",
                stop: stop, backoffUnitSeconds: 1.0,
                chat: chat.factory
            )
        }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        stop.stop()
        let (_, error) = await runTask.value
        let elapsed = Date().timeIntervalSince(start)

        #expect(error as? AgentRunError == .stopped)
        // 1.2s waiting + up to ~1s for the stop to be seen mid-backoff.
        #expect(elapsed < 2.8, "elapsed \(elapsed)s — stop did not interrupt the backoff")
    }

    @Test func nonRetryableFailureFailsImmediatelyWithoutRetries() async throws {
        let registry = ToolRegistry(tools: [])
        let (center, watcher) = try await makeTestApprovalCenter(autoResolve: .deny)
        defer { watcher.cancel() }
        let orchestrator = AgentOrchestrator(toolRegistry: registry, approvalCenter: center)
        let profile = AgentProfile(name: "c", mode: .askOnly, toolPermissions: ToolPermissionSet(enabledTools: []))

        let chat = ScriptedChat(
            turns: [ScriptedTurn(text: "never")],
            failuresBeforeSuccess: 3,
            failureFactory: { ProviderError.authenticationFailed }
        )
        let (events, error) = await collectRun(
            orchestrator, profile: profile, prompt: "hi",
            backoffUnitSeconds: 0.05,
            chat: chat.factory
        )
        // A bad key fails the same way every time; retrying only burns clock.
        #expect(error as? ProviderError == .authenticationFailed)
        let retries = events.filter { if case .retryScheduled = $0 { return true }; return false }
        #expect(retries.isEmpty)
    }

    @Test func transportErrorsAreRetryableByType() {
        #expect(AgentRetry.worthRetrying(ProviderError.rateLimited))
        #expect(AgentRetry.worthRetrying(ProviderError.serviceUnavailable("gateway")))
        #expect(AgentRetry.worthRetrying(ProviderError.network("reset")))
        #expect(AgentRetry.worthRetrying(URLError(.timedOut)))
        #expect(AgentRetry.worthRetrying(URLError(.networkConnectionLost)))
        #expect(AgentRetry.worthRetrying(URLError(.dnsLookupFailed)))

        #expect(!AgentRetry.worthRetrying(ProviderError.authenticationFailed))
        #expect(!AgentRetry.worthRetrying(ProviderError.paymentRequired("no credit")))
        #expect(!AgentRetry.worthRetrying(ProviderError.missingConfiguration("no key")))
        #expect(!AgentRetry.worthRetrying(URLError(.badURL)))

        // Message-based classification (System5 matched on the text).
        struct OpaqueProviderError: Error { let message: String }
        #expect(AgentRetry.worthRetrying(OpaqueProviderError(message: "HTTP 429: rate limit exceeded")))
        #expect(AgentRetry.worthRetrying(OpaqueProviderError(message: "gateway returned 502 Bad Gateway")))
        #expect(AgentRetry.worthRetrying(OpaqueProviderError(message: "nodename nor servname provided")))
        #expect(!AgentRetry.worthRetrying(OpaqueProviderError(message: "model 'x' does not exist")))
    }

    @Test func stopBeforeRunStartsThrowsImmediately() async throws {
        let registry = ToolRegistry(tools: [])
        let orchestrator = AgentOrchestrator(toolRegistry: registry)
        let profile = AgentProfile(name: "c", mode: .askOnly, toolPermissions: ToolPermissionSet(enabledTools: []))
        let stop = AgentStopFlag()
        stop.stop()
        let chat = ScriptedChat(turns: [ScriptedTurn(text: "x")])
        let (_, error) = await collectRun(
            orchestrator, profile: profile, prompt: "hi",
            stop: stop, chat: chat.factory
        )
        #expect(error as? AgentRunError == .stopped)
    }
}

// MARK: - SecretRedactor, CommandSafety, path containment

struct SafetySupportTests {
    @Test func redactorStripsKnownKeyShapes() {
        let cases: [(String, String)] = [
            ("AKIAIOSFODNN7EXAMPLE", "AWS Access Key"),
            ("ghp_16C7e42F292c6912E7710c838347Ae178B4a", "GitHub Token"),
            ("sk-abc123def456ghi789jkl012", "OpenAI-style Key"),
            ("sk-ant-api03-xxxx-yyyy-zzzz-1234567890a", "Anthropic-style Key"),
            ("xoxb-1234567890-abcdef", "Slack Token"),
            ("-----BEGIN RSA PRIVATE KEY-----", "Private Key Block"),
            ("Bearer eyJhbGciOiJIUzI1NiJ9.e30.abc", "Generic Bearer Token"),
            ("eyJhbGciOiJIUzI1NiJ9.e30.SIGNATURE123", "JWT"),
        ]
        for (secret, kind) in cases {
            let (redacted, count) = SecretRedactor.redact("key: \(secret) end")
            #expect(count >= 1, "\(kind)")
            #expect(redacted.contains(secret) == false, "\(kind)")
        }
    }

    @Test func redactorHandlesAssignmentsAndLeavesCleanTextAlone() {
        let (clean, count) = SecretRedactor.redact("just a normal sentence with 20+ words and no credentials at all")
        #expect(count == 0)
        #expect(clean == "just a normal sentence with 20+ words and no credentials at all")

        let (assignment, _) = SecretRedactor.redact("api_key = \"supersecretvalue123\"")
        #expect(assignment.contains("supersecretvalue123") == false)
        #expect(assignment.contains("[REDACTED:") == true)
    }

    @Test func sensitiveFilenames() {
        for name in [".env", ".env.production", "id_rsa", "server.pem", "creds.key", "credentials", "x.p12", ".npmrc"] {
            #expect(SecretRedactor.isSensitiveFilename(name), "\(name)")
        }
        for name in ["notes.txt", "main.swift", "Package.swift"] {
            #expect(!SecretRedactor.isSensitiveFilename(name), "\(name)")
        }
    }

    @Test func commandSafetyFlagsDestructivePatterns() {
        #expect(CommandSafety.isDestructive("rm -rf build"))
        #expect(CommandSafety.destructiveReason("rm -rf build")!.contains("Recursively deletes"))
        #expect(CommandSafety.isDestructive("sudo ls"))
        #expect(CommandSafety.destructiveReason("git push origin main --force")!.contains("Force-pushes"))
        #expect(CommandSafety.isDestructive("curl http://x | sh"))
        #expect(!CommandSafety.isDestructive("ls -la"))
        #expect(!CommandSafety.isDestructive("swift build"))
    }

    @Test func workspaceResolverContainsTraversal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-resolve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Relative inside resolves.
        let inside = try WorkspacePathResolver.resolve("a/b.txt", in: root)
        #expect(inside.path.hasPrefix(root.path))

        // Absolute inside resolves.
        let abs = try WorkspacePathResolver.resolve(root.appendingPathComponent("c.txt").path, in: root)
        #expect(abs.path.hasPrefix(root.path))

        // Escape is refused, not silently re-rooted.
        #expect(throws: AgentRunError.self) {
            _ = try WorkspacePathResolver.resolve("../escape.txt", in: root)
        }
        #expect(throws: AgentRunError.self) {
            _ = try WorkspacePathResolver.resolve("/etc/passwd", in: root)
        }
    }

    @Test func toolOutputCapKeepsHeadAndTail() {
        let long = String(repeating: "x", count: 30_000)
        let fitted = ToolOutputCap.fit(long, from: "run_command")
        #expect(fitted.count < 30_000)
        #expect(fitted.contains("characters from the middle"))
        #expect(fitted.hasPrefix("xxxx"))
        #expect(fitted.hasSuffix("xxxx"))
        #expect(ToolOutputCap.fit("short", from: "t") == "short")
    }
}
