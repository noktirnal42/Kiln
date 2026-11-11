import Foundation
import Testing
@testable import Kiln

@Suite("Tool phrases")
struct ToolPhraseTests {
    @Test func stepsReadAsAVerbAndWhatTheyTouched() {
        #expect(ToolPhrase.title(name: "run_command", argumentsJSON: #"{"command":"swift test"}"#) == .init(verb: "Ran", object: "swift test"))
        #expect(ToolPhrase.title(name: "edit_file", argumentsJSON: #"{"path":"Sources/Demo/Pagination.swift"}"#) == .init(verb: "Edited", object: "Pagination.swift"))
        #expect(ToolPhrase.title(name: "read_file", argumentsJSON: #"{"path":"/a/b/c.md"}"#) == .init(verb: "Read", object: "c.md"))
        #expect(ToolPhrase.title(name: "web_fetch", argumentsJSON: #"{"url":"https://example.com/page?x=1"}"#) == .init(verb: "Fetched", object: "example.com"))
        #expect(ToolPhrase.title(name: "kiln_todo_write", argumentsJSON: "{}") == .init(verb: "Updated", object: "the task list"))
        #expect(ToolPhrase.title(name: "git_commit", argumentsJSON: "{}") == .init(verb: "Ran git", object: "commit"))
        #expect(ToolPhrase.title(name: "re_get_cfg", argumentsJSON: "not json") == .init(verb: "Used", object: "re_get_cfg"))
        #expect(ToolPhrase.title(name: "write_file", argumentsJSON: "{}") == .init(verb: "Wrote", object: "a file"))
    }

    @Test func theLiveLineIsInTheProgressiveTense() {
        #expect(ToolPhrase.liveStatus(name: "run_command", argumentsJSON: #"{"command":"swift test"}"#) == "Running swift test")
        #expect(ToolPhrase.liveStatus(name: "edit_file", argumentsJSON: #"{"path":"a.swift"}"#) == "Editing a.swift")
        #expect(ToolPhrase.liveStatus(name: "web_search", argumentsJSON: #"{"query":"swift concurrency"}"#) == "Searching the web for swift concurrency")
        #expect(ToolPhrase.liveStatus(name: "edit_file", argumentsJSON: #"{"path":"a.swift"}"#, awaitingApproval: true) == "Waiting for your approval: editing a.swift")
    }

    @Test func aReplyThatIsOnlyAToolCallIsRecognised() {
        #expect(ToolPhrase.looksLikeToolCallText(#"{"name": "write_file", "arguments": {"path": "a"}}"#))
        #expect(ToolPhrase.looksLikeToolCallText("```json\n{\"name\":\"x\",\"arguments\":{}}\n```"))
        #expect(ToolPhrase.looksLikeToolCallText(#"[{"name": "a", "arguments": {}}]"#))
        #expect(!ToolPhrase.looksLikeToolCallText("The function takes a name and arguments."))
        #expect(!ToolPhrase.looksLikeToolCallText(#"{"just": "json"}"#))
        #expect(!ToolPhrase.looksLikeToolCallText(""))
    }

    @Test func summariesAreSentences() {
        func item(_ name: String, _ path: String? = nil, failed: Bool = false) -> ToolActivityItem {
            ToolActivityItem(name: name, argumentsJSON: path.map { "{\"path\":\"\($0)\"}" } ?? "{}", failed: failed)
        }
        #expect(ToolActivitySummary.line(for: [item("run_command"), item("edit_file", "a")]) == "Ran 1 command and edited 1 file")
        #expect(ToolActivitySummary.line(for: [item("run_command"), item("edit_file", "a"), item("read_file", "b")]) == "Ran 1 command, edited 1 file and read 1 file")
        #expect(ToolActivitySummary.line(for: [item("run_command", failed: true), item("read_file", "b")]) == "Ran 1 command, read 1 file, 1 failed")
    }
}
