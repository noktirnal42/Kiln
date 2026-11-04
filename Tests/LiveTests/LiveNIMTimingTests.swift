import Foundation
import Testing
@testable import Kiln

/// Time-to-first-byte probe for NVIDIA NIM (issue #23): the same tiny prompt streamed and not streamed, with and without extra
/// reasoning fields, per model. Opt-in (`TEST_RUNNER_KILN_LIVE=1`); uses the key saved in Settings and never prints it.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["KILN_LIVE_NIM"] == "1"), .serialized)
struct LiveNIMTimingTests {
    private func measure(key: String, body: [String: Any], stream: Bool) async -> String {
        var request = URLRequest(url: URL(string: "https://integrate.api.nvidia.com/v1/chat/completions")!, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload = body; payload["stream"] = stream
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        let start = Date()
        do {
            if stream {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                let headers = Date().timeIntervalSince(start)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                var firstContent: TimeInterval?
                for try await line in bytes.lines where line.hasPrefix("data:") && line.contains("\"content\"") && !line.contains("\"content\":null") && !line.contains("\"content\":\"\"") {
                    firstContent = Date().timeIntervalSince(start); break
                }
                return String(format: "HTTP %d headers %.1fs first-content %@ ", status, headers, firstContent.map { String(format: "%.1fs", $0) } ?? "never")
            } else {
                let (data, response) = try await URLSession.shared.data(for: request)
                return String(format: "HTTP %d full-response %.1fs (%d bytes)", (response as? HTTPURLResponse)?.statusCode ?? 0, Date().timeIntervalSince(start), data.count)
            }
        } catch { return String(format: "error after %.1fs: %@", Date().timeIntervalSince(start), "\(error)".prefix(80) as CVarArg) }
    }

    @Test func recordTimeToFirstTokenPerModelAndRequestShape() async throws {
        let key = try #require(KeychainService().secretProvider(module: providersKeychainModule, key: "nvidia-nim")(), "no NVIDIA NIM key in Settings")
        var listRequest = URLRequest(url: URL(string: "https://integrate.api.nvidia.com/v1/models")!, timeoutInterval: 30)
        listRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: listRequest)
        let ids = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"].flatMap { $0 as? [[String: Any]] }?.compactMap { $0["id"] as? String } ?? []
        let wanted = ids.filter { $0.lowercased().contains("gemma-4-31b") || $0.lowercased().contains("glm-5.3-flash") }
        print("NIM models probed: \(wanted)")
        #expect(!wanted.isEmpty, "none of the issue's models are listed")
        let control = ids.first { $0.hasSuffix("meta/llama-3.3-70b-instruct") }
        for model in wanted + (control.map { [$0] } ?? []) {
            let base: [String: Any] = ["model": model, "messages": [["role": "user", "content": "Reply with the single word: ready"]], "max_tokens": 32]
            print("NIM \(model) | streaming            | " + (await measure(key: key, body: base, stream: true)))
            print("NIM \(model) | non-streaming        | " + (await measure(key: key, body: base, stream: false)))
            var thinkingOff = base; thinkingOff["chat_template_kwargs"] = ["enable_thinking": false]
            print("NIM \(model) | streaming, thinking off | " + (await measure(key: key, body: thinkingOff, stream: true)))
        }
    }
}
