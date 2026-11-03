import Foundation
import Testing
import AxiomCore
@testable import Kiln

@MainActor
struct REAgentToolsTests {
    private func makeTools() -> [REAgentTool] {
        let module = REModule()
        return REMCPTools.definitions.map { REAgentTool(definition: $0, module: module) }
    }

    @Test func everyRECallIsExposedWithAPrefixedName() {
        let tools = makeTools()
        #expect(tools.count == REMCPTools.definitions.count)
        #expect(tools.allSatisfy { $0.spec.name.hasPrefix(REAgentTools.prefix) })
        #expect(Set(tools.map { $0.spec.name }).count == tools.count)
    }

    @Test func readOnlyDefinitionsMapToReadPermission() {
        for tool in makeTools() {
            let readOnly = REMCPTools.definitions.first { REAgentTools.prefix + $0.name == tool.spec.name }?.readOnly
            let expected: ToolPermissionLevel = tool.spec.name == "re_analyze_binary" ? .execute : (readOnly == true ? .read : .write)
            #expect(tool.spec.permission == expected)
        }
    }

    @Test func importBinaryIsAWriteAndRequiresPath() throws {
        let tool = try #require(makeTools().first { $0.spec.name == "re_import_binary" })
        #expect(tool.spec.permission == .write)
        let path = try #require(tool.spec.parameters.first { $0.name == "path" })
        #expect(path.required)
        #expect(path.type == "string")
    }

    @Test func missingRequiredArgumentFailsWithSpecificReason() async throws {
        let module = REModule()
        let tool = REAgentTool(
            definition: try #require(REMCPTools.definitions.first { $0.name == "import_binary" }),
            module: module
        )
        let context = ToolExecutionContext(
            workspaceRoot: nil,
            conversationID: UUID(),
            redactSecrets: true,
            services: ToolServices()
        )
        await #expect(throws: REMToolError.self) {
            _ = try await tool.execute(argumentsJSON: "{}", context: context)
        }
    }

    @Test func lifecycleEventsAreHiddenUnlessRequested() {
        let now = Date()
        let entries = [
            BusEntry(eventType: "module.lifecycle", sourceModule: "com.kiln.kernel", timestamp: now),
            BusEntry(eventType: "model.switched", sourceModule: "com.kiln.modelregistry", timestamp: now),
        ]
        let hidden = SidebarView.visibleBusEntries(entries, showLifecycle: false)
        #expect(hidden.map(\.eventType) == ["model.switched"])
        #expect(SidebarView.visibleBusEntries(entries, showLifecycle: true).count == 2)
    }
}

@MainActor
struct REProjectIDTests {
    @Test func anImportReportsTheIDEveryOtherToolAccepts_andEitherIDWorks() async throws {
        let module = REModule()
        let output = try await REMCPTools.call(tool: "import_binary", arguments: ["path": "/bin/ls"], service: module)
        let summary = try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let projectID = try #require(summary["project_id"] as? String)
        let analysisID = try #require(summary["id"] as? String)

        for id in Set([projectID, analysisID]) {
            let strings = try await REMCPTools.call(tool: "search_strings", arguments: ["project_id": id, "pattern": "usage"], service: module)
            #expect(strings.lowercased().contains("usage"), "search_strings failed for id \(id)")
        }
    }
}
