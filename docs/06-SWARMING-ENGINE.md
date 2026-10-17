# SuperMetaApp — Swarming Engine Module Specification

## Overview

The **Swarming Engine Module** provides multi-agent orchestration capabilities inspired by System5, enabling multiple AI agents to collaborate on complex tasks through a coordination bus, shared workspace, policy enforcement, and human-in-the-loop approvals.

---

## Module Identity

```json
{
  "identifier": "com.supermeta.swarming",
  "displayName": "Swarming Engine",
  "version": "1.0.0",
  "category": "ai",
  "icon": "ant.circle.fill",
  "requiredCapabilities": [
    "fileSystem.readWrite",
    "process.spawn",
    "network.client",
    "network.server"
  ],
  "provides": [
    "swarmOrchestrator",
    "agentPool",
    "coordinationBus",
    "consensusEngine",
    "taskDecomposer",
    "sandboxManager",
    "approvalQueue",
    "behaviorMonitor",
    "auditLog"
  ]
}
```

---

## Architecture

```
SwarmingEngineModule/
├── Module.swift
├── Orchestrator/
│   ├── SwarmOrchestrator.swift
│   ├── TaskDecomposer.swift
│   ├── AgentPool.swift
│   ├── CoordinationBus.swift
│   ├── ConsensusEngine.swift
│   └── WorkflowEngine.swift
├── Agents/
│   ├── BaseAgent.swift
│   ├── PlannerAgent.swift
│   ├── ImplementerAgent.swift
│   ├── ReviewerAgent.swift
│   ├── ResearcherAgent.swift
│   ├── CoderAgent.swift
│   ├── TesterAgent.swift
│   ├── DocumenterAgent.swift
│   ├── ArchitectAgent.swift
│   ├── DebuggerAgent.swift
│   └── CustomAgentFactory.swift
├── Policies/
│   ├── SandboxPolicy.swift
│   ├── NetworkPolicy.swift
│   ├── ApprovalPolicy.swift
│   ├── ResourcePolicy.swift
│   ├── CapabilityPolicy.swift
│   └── PolicyEngine.swift
├── Sandbox/
│   ├── SandboxManager.swift
│   ├── DockerBackend.swift
│   ├── SeatbeltBackend.swift
│   ├── SubprocessBackend.swift
│   ├── SandboxProfile.swift
│   └── ResourceLimits.swift
├── Coordination/
│   ├── CoordinationBus.swift
│   ├── MessageRouter.swift
│   ├── SharedMemory.swift
│   ├── TaskQueue.swift
│   ├── EventLog.swift
│   └── ConsensusProtocol.swift
├── Approvals/
│   ├── ApprovalQueue.swift
│   ├── ApprovalUI.swift
│   ├── EscalationEngine.swift
│   ├── ApprovalPolicy.swift
│   └── AutoApprovalRules.swift
├── Monitoring/
│   ├── BehaviorMonitor.swift
│   ├── AuditLog.swift
│   ├── TripwireEngine.swift
│   ├── LLMRubric.swift
│   ├── AnomalyDetector.swift
│   └── MetricsCollector.swift
├── UI/
│   ├── SwarmDashboard.swift
│   ├── AgentActivityView.swift
│   ├── TaskGraphView.swift
│   ├── ApprovalView.swift
│   ├── MonitorView.swift
│   ├── AuditView.swift
│   └── PolicyEditor.swift
└── Persistence/
    ├── SwarmStore.swift
    ├── TaskStore.swift
    ├── AgentStateStore.swift
    └── AuditStore.swift
```

---

## Core Orchestration

### Swarm Orchestrator

```swift
final class SwarmOrchestrator: Sendable {
    private let agentPool: AgentPool
    private let coordinationBus: CoordinationBus
    private let policyEngine: PolicyEngine
    private let approvalQueue: ApprovalQueue
    private let behaviorMonitor: BehaviorMonitor
    private let auditLog: AuditLog
    
    func executeSwarm(
        task: SwarmTask,
        configuration: SwarmConfiguration
    ) async throws -> SwarmResult {
        // 1. Create swarm context
        let context = SwarmContext(
            task: task,
            configuration: configuration,
            workspace: configuration.workspace,
            modelRegistry: ModelRegistry.shared,
            mcpClient: MCPClientService.shared
        )
        
        // 2. Decompose task into subtasks
        let subtasks = try await TaskDecomposer.decompose(task, context: context)
        
        // 3. Spawn agents
        let agents = try await agentPool.spawnAgents(for: subtasks, context: context)
        
        // 4. Execute with coordination
        let result = try await executeWithCoordination(agents, subtasks, context)
        
        // 5. Collect and synthesize results
        return try await synthesizeResults(result, context)
    }
    
    private func executeWithCoordination(
        _ agents: [BaseAgent],
        _ subtasks: [Subtask],
        _ context: SwarmContext
    ) async throws -> SwarmExecutionResult {
        // Start all agents
        await withTaskGroup(of: AgentResult.self) { group in
            for (agent, subtask) in zip(agents, subtasks) {
                group.addTask {
                    try await agent.execute(subtask: subtask, context: context)
                }
            }
            
            // Monitor coordination bus
            group.addTask {
                await self.monitorCoordination(context)
            }
            
            // Monitor behavior
            group.addTask {
                await self.behaviorMonitor.monitor(agents, context: context)
            }
            
            var results: [AgentResult] = []
            for try await result in group {
                results.append(result)
            }
            
            return SwarmExecutionResult(agentResults: results)
        }
    }
}
```

### Task Decomposer

```swift
final class TaskDecomposer: Sendable {
    func decompose(_ task: SwarmTask, context: SwarmContext) async throws -> [Subtask] {
        let prompt = """
        Decompose the following task into parallelizable subtasks:
        
        Task: \(task.description)
        Context: \(context.workspace.description)
        Available Agents: \(AgentType.allCases.map(\.rawValue).joined(separator: ", "))
        
        Return JSON array of subtasks with:
        - id, type, description, dependencies, assignedAgent, priority
        """
        
        let provider = await ModelRegistry.shared.resolveBestProvider(for: .planning)
        let request = ChatRequest(messages: [Message(role: .user, content: prompt)])
        
        let response = try await provider.streamChat(request, reasoning: .default)
        let fullResponse = try await response.collect()
        
        return try JSONDecoder().decode([Subtask].self, from: fullResponse.data(using: .utf8)!)
    }
}

struct Subtask: Identifiable, Codable, Sendable {
    let id: UUID
    let type: SubtaskType
    let description: String
    let dependencies: [UUID]
    let assignedAgent: AgentType
    let priority: Priority
    let estimatedDuration: TimeInterval
    let requiredCapabilities: [Capability]
}

enum SubtaskType: String, Codable, Sendable {
    case planning, implementation, review, testing, documentation
    case research, debugging, architecture, refactoring, deployment
}
```

---

## Agent Types

### Base Agent

```swift
protocol BaseAgent: Sendable {
    var id: String { get }
    var type: AgentType { get }
    var capabilities: [Capability] { get }
    var profile: AgentProfile { get }
    
    func execute(subtask: Subtask, context: SwarmContext) async throws -> AgentResult
    func handleMessage(_ message: CoordinationMessage) async
    func requestCapability(_ capability: Capability) async -> CapabilityGrant
    func reportBlocker(_ blocker: Blocker) async
}

struct AgentProfile: Codable, Sendable {
    let name: String
    let systemPrompt: String
    let modelPreferences: ModelPreferences
    let toolPermissions: [String: PermissionLevel]
    let maxConcurrentTasks: Int
    let timeout: TimeInterval
}

enum AgentType: String, Codable, CaseIterable, Sendable {
    case planner = "planner"
    case implementer = "implementer"
    case reviewer = "reviewer"
    case researcher = "researcher"
    case coder = "coder"
    case tester = "tester"
    case documenter = "documenter"
    case architect = "architect"
    case debugger = "debugger"
    case custom = "custom"
}
```

### Specialized Agents

```swift
final class PlannerAgent: BaseAgent {
    let type = AgentType.planner
    let capabilities: [Capability] = [.planning, .taskDecomposition, .dependencyAnalysis]
    
    func execute(subtask: Subtask, context: SwarmContext) async throws -> AgentResult {
        // Create detailed execution plan
        let plan = try await createPlan(subtask, context)
        
        // Publish plan to coordination bus
        await context.coordinationBus.publish(PlanMessage(plan: plan, from: id))
        
        return AgentResult(
            subtaskID: subtask.id,
            output: plan,
            artifacts: [plan.toArtifact()],
            nextActions: plan.steps.map { $0.toSubtask() }
        )
    }
}

final class ImplementerAgent: BaseAgent {
    let type = AgentType.implementer
    let capabilities: [Capability] = [.coding, .fileOperations, .git, .terminal, .build]
    
    func execute(subtask: Subtask, context: SwarmContext) async throws -> AgentResult {
        // Implement code changes
        let changes = try await implement(subtask, context)
        
        // Request approval for writes
        for change in changes.writes {
            let approval = await context.approvalQueue.request(
                for: .fileWrite(change.path),
                reason: change.reason
            )
            guard approval.granted else { throw AgentError.approvalDenied }
        }
        
        // Apply changes
        try await applyChanges(changes, context)
        
        // Run tests
        let testResults = try await runTests(for: changes, context)
        
        return AgentResult(
            subtaskID: subtask.id,
            output: changes.summary,
            artifacts: changes.artifacts + testResults.artifacts,
            metrics: ["filesChanged": changes.files.count, "testsPassed": testResults.passed]
        )
    }
}

final class ReviewerAgent: BaseAgent {
    let type = AgentType.reviewer
    let capabilities: [Capability] = [.codeReview, .securityAnalysis, .performanceAnalysis]
    
    func execute(subtask: Subtask, context: SwarmContext) async throws -> AgentResult {
        // Review implementation
        let review = try await reviewImplementation(subtask, context)
        
        // Check for security issues
        let securityIssues = try await scanForSecurityIssues(subtask, context)
        
        // Check performance
        let perfIssues = try await analyzePerformance(subtask, context)
        
        return AgentResult(
            subtaskID: subtask.id,
            output: review.summary,
            artifacts: [review.toArtifact()],
            issues: securityIssues + perfIssues,
            approval: review.approval
        )
    }
}

final class ResearcherAgent: BaseAgent {
    let type = AgentType.researcher
    let capabilities: [Capability] = [.webSearch, .codeSearch, .documentationLookup, .apiExploration]
    
    func execute(subtask: Subtask, context: SwarmContext) async throws -> AgentResult {
        // Research using web, code, docs
        let findings = try await research(subtask, context)
        
        // Synthesize findings
        let synthesis = try await synthesizeFindings(findings, context)
        
        return AgentResult(
            subtaskID: subtask.id,
            output: synthesis,
            artifacts: [synthesis.toArtifact()],
            sources: findings.sources
        )
    }
}
```

---

## Coordination Bus

### Message Passing

```swift
actor CoordinationBus: Sendable {
    private var subscribers: [String: [MessageHandler]] = [:]
    private var messageHistory: [CoordinationMessage] = []
    
    func publish(_ message: CoordinationMessage) async {
        messageHistory.append(message)
        
        // Route to subscribers
        if let handlers = subscribers[message.topic] {
            await withTaskGroup(of: Void.self) { group in
                for handler in handlers {
                    group.addTask { await handler(message) }
                }
            }
        }
        
        // Also broadcast to wildcard subscribers
        if let handlers = subscribers["*"] {
            await withTaskGroup(of: Void.self) { group in
                for handler in handlers {
                    group.addTask { await handler(message) }
                }
            }
        }
    }
    
    func subscribe(to topic: String, handler: @escaping @Sendable (CoordinationMessage) async -> Void) async {
        subscribers[topic, default: []].append(handler)
    }
    
    func queryHistory(topic: String?, since: Date?, limit: Int) async -> [CoordinationMessage] {
        var filtered = messageHistory
        
        if let topic { filtered = filtered.filter { $0.topic == topic } }
        if let since { filtered = filtered.filter { $0.timestamp >= since } }
        
        return Array(filtered.suffix(limit))
    }
}

struct CoordinationMessage: Identifiable, Codable, Sendable {
    let id: UUID
    let topic: String
    let fromAgent: String
    let toAgent: String?  // nil = broadcast
    let type: MessageType
    let payload: Data
    let timestamp: Date
    let replyTo: UUID?
}

enum MessageType: String, Codable, Sendable {
    case plan, progress, result, blocker, question, approval
    case capabilityRequest, capabilityGrant, resourceRequest
    case sync, heartbeat, shutdown
}
```

### Shared Memory

```swift
actor SharedMemory: Sendable {
    private var store: [String: SharedValue] = [:]
    private var locks: [String: AsyncLock] = [:]
    
    func write<T: Codable & Sendable>(_ key: String, value: T, version: Int? = nil) async throws {
        let lock = locks[key, default: AsyncLock()]
        await lock.lock()
        defer { lock.unlock() }
        
        if let version, store[key]?.version != version {
            throw SharedMemoryError.versionConflict
        }
        
        store[key] = SharedValue(
            data: try JSONEncoder().encode(value),
            version: (store[key]?.version ?? 0) + 1,
            updatedBy: Thread.current.description,
            timestamp: Date()
        )
    }
    
    func read<T: Codable & Sendable>(_ key: String) async -> T? {
        guard let value = store[key] else { return nil }
        return try? JSONDecoder().decode(T.self, from: value.data)
    }
    
    func atomicUpdate<T: Codable & Sendable>(
        _ key: String,
        transform: @Sendable (T?) async throws -> T
    ) async throws {
        let lock = locks[key, default: AsyncLock()]
        await lock.lock()
        defer { lock.unlock() }
        
        let current = try? JSONDecoder().decode(T.self, from: store[key]?.data ?? Data())
        let newValue = try await transform(current)
        try await write(key, value: newValue)
    }
}
```

---

## Consensus Engine

### Multi-Agent Agreement

```swift
final class ConsensusEngine: Sendable {
    func reachConsensus(
        proposal: Proposal,
        participants: [BaseAgent],
        threshold: ConsensusThreshold
    ) async throws -> ConsensusResult {
        var votes: [Vote] = []
        
        // Collect votes from all participants
        await withTaskGroup(of: Vote.self) { group in
            for agent in participants {
                group.addTask {
                    await agent.vote(on: proposal)
                }
            }
            
            for await vote in group {
                votes.append(vote)
            }
        }
        
        // Evaluate consensus
        let result = evaluateConsensus(votes, threshold: threshold)
        
        // Record in audit log
        await AuditLog.shared.record(ConsensusEvent(
            proposal: proposal,
            votes: votes,
            result: result
        ))
        
        return result
    }
    
    private func evaluateConsensus(
        _ votes: [Vote],
        threshold: ConsensusThreshold
    ) -> ConsensusResult {
        let approve = votes.filter { $0.decision == .approve }.count
        let reject = votes.filter { $0.decision == .reject }.count
        let abstain = votes.filter { $0.decision == .abstain }.count
        
        let total = votes.count
        let approveRatio = Double(approve) / Double(total)
        
        let reached: Bool
        switch threshold {
        case .unanimous: reached = reject == 0 && abstain == 0
        case .supermajority: reached = approveRatio >= 0.67
        case .majority: reached = approveRatio > 0.5
        case .plurality: reached = approve > reject
        }
        
        return ConsensusResult(
            reached: reached,
            approveCount: approve,
            rejectCount: reject,
            abstainCount: abstain,
            votes: votes
        )
    }
}

struct Proposal: Codable, Sendable {
    let id: UUID
    let title: String
    let description: String
    let action: ProposalAction
    let requiredCapabilities: [Capability]
    let expiresAt: Date?
}

enum ProposalAction: Codable, Sendable {
    case mergeCode(path: String, diff: String)
    case deployService(name: String, config: Data)
    case modifyPolicy(policy: String, changes: Data)
    case allocateResource(resource: String, amount: Double)
    case custom(type: String, payload: Data)
}
```

---

## Sandbox Management

### Multi-Backend Sandbox

```swift
protocol SandboxBackend: Sendable {
    var name: String { get }
    var isolationLevel: IsolationLevel { get }
    
    func create(profile: SandboxProfile) async throws -> SandboxInstance
    func destroy(_ instance: SandboxInstance) async throws
    func execute(_ instance: SandboxInstance, command: SandboxCommand) async throws -> SandboxResult
    func copyTo(_ instance: SandboxInstance, src: URL, dst: String) async throws
    func copyFrom(_ instance: SandboxInstance, src: String, dst: URL) async throws
}

enum IsolationLevel: String, Codable, Sendable, Comparable {
    case none = "none"           // Direct execution
    case seatbelt = "seatbelt"   // macOS sandbox-exec
    case docker = "docker"       // Container isolation
    
    static func < (lhs: IsolationLevel, rhs: IsolationLevel) -> Bool {
        let order: [IsolationLevel] = [.none, .seatbelt, .docker]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

final class SandboxManager: Sendable {
    private let backends: [SandboxBackend] = [
        DockerBackend(),
        SeatbeltBackend(),
        SubprocessBackend()
    ]
    
    func createSandbox(
        for agent: BaseAgent,
        profile: SandboxProfile
    ) async throws -> SandboxInstance {
        // Select best available backend
        let backend = selectBackend(for: profile.requiredIsolation)
        
        let instance = try await backend.create(profile: profile)
        
        // Set up agent environment
        try await setupAgentEnvironment(instance, agent: agent)
        
        return instance
    }
    
    private func selectBackend(for required: IsolationLevel) -> SandboxBackend {
        backends
            .filter { $0.isolationLevel >= required }
            .max(by: { $0.isolationLevel < $1.isolationLevel })
            ?? backends.last!
    }
}
```

### Docker Backend

```swift
final class DockerBackend: SandboxBackend {
    let name = "docker"
    let isolationLevel = IsolationLevel.docker
    
    func create(profile: SandboxProfile) async throws -> SandboxInstance {
        let containerName = "swarm-\(UUID().uuidString.prefix(8))"
        
        var args = [
            "run", "-d", "--name", containerName,
            "--cpus", String(profile.cpuLimit),
            "--memory", "\(profile.memoryLimit)GB",
            "--network", profile.networkAccess ? "bridge" : "none",
            "-v", "\(profile.workspace.path):/workspace:\(profile.readOnly ? "ro" : "rw")"
        ]
        
        // Add capability drops
        for cap in profile.droppedCapabilities {
            args += ["--cap-drop", cap]
        }
        
        // Add security options
        if profile.noNewPrivileges {
            args += ["--security-opt", "no-new-privileges"]
        }
        
        args += [profile.image, "sleep", "infinity"]
        
        let result = try await ProcessRunner.run("docker", args: args)
        let containerID = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return DockerSandboxInstance(
            id: containerID,
            name: containerName,
            profile: profile
        )
    }
}
```

### Seatbelt Backend (macOS sandbox-exec)

```swift
final class SeatbeltBackend: SandboxBackend {
    let name = "seatbelt"
    let isolationLevel = IsolationLevel.seatbelt
    
    func create(profile: SandboxProfile) async throws -> SandboxInstance {
        let profileText = generateSeatbeltProfile(profile)
        let profilePath = try writeProfileToTempFile(profileText)
        
        return SeatbeltSandboxInstance(
            id: UUID().uuidString,
            profilePath: profilePath,
            profile: profile
        )
    }
    
    func execute(_ instance: SandboxInstance, command: SandboxCommand) async throws -> SandboxResult {
        let seatbeltInstance = instance as! SeatbeltSandboxInstance
        
        let args = [
            "sandbox-exec", "-f", seatbeltInstance.profilePath.path,
            command.executable
        ] + command.arguments
        
        return try await ProcessRunner.run(args[0], args: Array(args.dropFirst()))
    }
    
    private func generateSeatbeltProfile(_ profile: SandboxProfile) -> String {
        """
        (version 1)
        (deny default)
        (allow file-read* (regex "^/workspace"))
        \(profile.readOnly ? "(deny file-write*)" : "(allow file-write* (regex \"^/workspace\"))")
        \(profile.networkAccess ? "(allow network*)" : "(deny network*)")
        (allow process-exec (regex "^/usr/bin/"))
        (deny process-fork)
        (resource-limits (cpu \(profile.cpuLimit)) (memory \(profile.memoryLimit * 1024 * 1024 * 1024)))
        """
    }
}
```

---

## Approval System

### Approval Queue

```swift
actor ApprovalQueue: Sendable {
    private var pending: [ApprovalRequest] = []
    private var handlers: [String: ApprovalHandler] = [:]
    
    func request(
        for action: ApprovalAction,
        reason: String,
        requester: String,
        policy: ApprovalPolicy
    ) async -> ApprovalResult {
        let request = ApprovalRequest(
            id: UUID(),
            action: action,
            reason: reason,
            requester: requester,
            policy: policy,
            timestamp: Date()
        )
        
        // Check auto-approval rules
        if let autoResult = policy.autoApprove(request) {
            return autoResult
        }
        
        // Add to queue
        pending.append(request)
        
        // Notify UI
        await notifyUI(request)
        
        // Wait for decision
        return await waitForDecision(request.id)
    }
    
    private func waitForDecision(_ id: UUID) async -> ApprovalResult {
        await withCheckedContinuation { continuation in
            handlers[id.uuidString] = { result in
                continuation.resume(returning: result)
            }
        }
    }
    
    func respond(_ id: UUID, result: ApprovalResult) async {
        if let handler = handlers.removeValue(forKey: id.uuidString) {
            await handler(result)
        }
        pending.removeAll { $0.id == id }
    }
}

struct ApprovalRequest: Identifiable, Codable, Sendable {
    let id: UUID
    let action: ApprovalAction
    let reason: String
    let requester: String
    let policy: ApprovalPolicy
    let timestamp: Date
}

enum ApprovalAction: Codable, Sendable {
    case fileWrite(path: String)
    case fileDelete(path: String)
    case shellCommand(command: String)
    case networkRequest(url: String)
    case capabilityRequest(capability: Capability)
    case policyChange(policy: String)
    case custom(type: String, payload: Data)
}

enum ApprovalResult: Codable, Sendable {
    case granted
    case denied(reason: String)
    case modified(modifiedAction: ApprovalAction)
}
```

### Approval UI

```swift
struct ApprovalView: View {
    @State var pendingRequests: [ApprovalRequest] = []
    
    var body: some View {
        List(pendingRequests) { request in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: request.action.icon)
                        .foregroundStyle(request.action.color)
                    Text(request.action.title)
                        .font(.headline)
                    Spacer()
                    Text(request.requester)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Text(request.reason)
                    .font(.body)
                
                // Show diff for file changes
                if case .fileWrite(let path) = request.action,
                   let diff = request.diff {
                    DiffView(diff: diff)
                }
                
                // Show command for shell
                if case .shellCommand(let cmd) = request.action {
                    CodeView(code: cmd, language: "bash")
                }
                
                HStack {
                    Button("Deny") { deny(request) }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    
                    if case .modified(let modified) = request.policy.suggestedModification {
                        Button("Allow Modified") { allowModified(request, modified) }
                            .buttonStyle(.borderedProminent)
                    }
                    
                    Button("Allow") { allow(request) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }
}
```

---

## Behavior Monitoring

### Tripwire Engine

```swift
final class TripwireEngine: Sendable {
    let tripwires: [Tripwire] = [
        // Network tripwires
        Tripwire(
            name: "Unexpected Network Egress",
            condition: .networkEgress(to: .unapprovedHosts),
            severity: .critical,
            action: .pauseAndAlert
        ),
        Tripwire(
            name: "SSRF Attempt",
            condition: .networkEgress(to: .localNetwork),
            severity: .critical,
            action: .pauseAndAlert
        ),
        
        // File system tripwires
        Tripwire(
            name: "Out-of-Scope Write",
            condition: .fileWrite(outside: .workspace),
            severity: .high,
            action: .blockAndAlert
        ),
        Tripwire(
            name: "Sensitive File Access",
            condition: .fileRead(matching: [".env", "*.key", "*.pem", "id_rsa"]),
            severity: .high,
            action: .alert
        ),
        
        // Process tripwires
        Tripwire(
            name: "Privilege Escalation",
            condition: .shellCommand(matching: ["sudo", "su ", "chmod +s", "setuid"]),
            severity: .critical,
            action: .pauseAndAlert
        ),
        Tripwire(
            name: "Destructive Command",
            condition: .shellCommand(matching: ["rm -rf /", "dd if=", "mkfs", "> /dev/sd"]),
            severity: .critical,
            action: .blockAndAlert
        ),
        
        // Behavior tripwires
        Tripwire(
            name: "Excessive Tool Calls",
            condition: .toolCallRate(exceeds: 100, perMinute: 1),
            severity: .medium,
            action: .throttle
        ),
        Tripwire(
            name: "Repeated Failures",
            condition: .consecutiveFailures(exceeds: 5),
            severity: .medium,
            action: .pauseAndAlert
        )
    ]
    
    func evaluate(_ event: AgentEvent, agent: BaseAgent) async -> [TripwireMatch] {
        return tripwires.compactMap { tripwire in
            guard tripwire.condition.matches(event) else { return nil }
            return TripwireMatch(tripwire: tripwire, event: event, agent: agent.id)
        }
    }
}

enum TripwireAction: Codable, Sendable {
    case alert
    case blockAndAlert
    case pauseAndAlert
    case throttle
    case terminate
}
```

### LLM Rubric Monitor

```swift
final class LLMRubricMonitor: Sendable {
    func evaluate(
        agent: BaseAgent,
        recentActivity: [AgentEvent],
        rubric: MonitoringRubric
    ) async -> MonitoringResult {
        let prompt = """
        Evaluate the following agent activity against the rubric:
        
        Agent: \(agent.id) (\(agent.type))
        Recent Events: \(recentActivity.map(\.description).joined(separator: "\n"))
        
        Rubric:
        \(rubric.criteria.map { "- \($0.name): \($0.description)" }.joined(separator: "\n"))
        
        Score each criterion 1-7 and provide overall assessment.
        """
        
        let provider = await ModelRegistry.shared.resolveBestProvider(for: .monitoring)
        let response = try await provider.streamChat(
            ChatRequest(messages: [Message(role: .user, content: prompt)]),
            reasoning: .balanced
        )
        
        return try await parseMonitoringResponse(response)
    }
}

struct MonitoringRubric: Codable, Sendable {
    let criteria: [RubricCriterion]
    
    static let `default` = MonitoringRubric(criteria: [
        RubricCriterion(name: "Task Progress", description: "Is the agent making meaningful progress?"),
        RubricCriterion(name: "Scope Adherence", description: "Is the agent staying within assigned scope?"),
        RubricCriterion(name: "Code Quality", description: "Is produced code clean, tested, documented?"),
        RubricCriterion(name: "Security", description: "Are there security concerns in actions?"),
        RubricCriterion(name: "Communication", description: "Is the agent communicating clearly via bus?"),
        RubricCriterion(name: "Resource Usage", description: "Is resource consumption reasonable?"),
        RubricCriterion(name: "Error Handling", description: "Does the agent handle errors appropriately?")
    ])
}
```

---

## Audit Logging

### Hash-Chained Audit Log

```swift
final class AuditLog: Sendable {
    private let store: AuditStore
    private var head: AuditEntry?
    
    func record(_ event: AuditEvent) async throws -> AuditEntry {
        let previousHash = head?.hash
        let entry = AuditEntry(
            id: UUID(),
            event: event,
            previousHash: previousHash,
            timestamp: Date()
        )
        
        // Compute hash
        entry.hash = computeHash(entry)
        
        // Store
        try await store.append(entry)
        head = entry
        
        return entry
    }
    
    func verifyChain() async -> VerificationResult {
        var current = try await store.first()
        var previousHash: Data? = nil
        var valid = true
        var tamperedIndex: Int?
        
        var index = 0
        while let entry = current {
            // Verify hash chain
            let expectedHash = computeHash(entry)
            if entry.hash != expectedHash {
                valid = false
                tamperedIndex = index
                break
            }
            
            // Verify link to previous
            if entry.previousHash != previousHash {
                valid = false
                tamperedIndex = index
                break
            }
            
            previousHash = entry.hash
            current = try await store.next(after: entry.id)
            index += 1
        }
        
        return VerificationResult(valid: valid, tamperedIndex: tamperedIndex, entriesChecked: index)
    }
    
    func export(since: Date?, format: ExportFormat) async throws -> Data {
        let entries = try await store.query(since: since)
        
        switch format {
        case .json:
            return try JSONEncoder().encode(entries)
        case .jsonl:
            return entries.map { try JSONEncoder().encode($0) }.joined(separator: "\n").data(using: .utf8)!
        case .signedBundle:
            return try createSignedBundle(entries)
        }
    }
}

struct AuditEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let event: AuditEvent
    let previousHash: Data?
    let hash: Data
    let timestamp: Date
}
```

---

## Integration with SuperMetaApp

### Cross-Module Workflows

```
+-------------------+     +-------------------+
|  SwarmingEngine   |---->|  AgenticConsole   |
|  (Orchestrate)    |     |  (Monitor/Control)|
+-------------------+     +-------------------+
        |                       |
        v                       v
+---------------------------------------------+
|           Shared Coordination Bus            |
|  * Task Queue    * Shared Memory             |
|  * Agent States  * Approval Queue            |
|  * Audit Log     * Metrics                   |
+---------------------------------------------+
        |
        v
+-------------------+     +-------------------+
|  DevPlatform      |---->|  ModelLab         |
|  (Execute Code)   |     |  (Provide Models) |
+-------------------+     +-------------------+
```

### Shared Services Used

| Service | Usage |
|---------|-------|
| ModelRegistry | Agent model selection, consensus voting |
| MCPClient | External tools for agents |
| WorkspaceManager | Shared workspace, security-scoped bookmarks |
| TerminalService | Sandbox shell access |
| GitService | Version control for swarm outputs |
| FileIndexService | Code search for researcher agents |
| SettingsService | Policy configs, sandbox profiles |
| KeychainService | Sandbox credentials, API keys |

---

## Swarm Dashboard UI

```swift
struct SwarmDashboard: View {
    @State var activeSwarms: [SwarmExecution] = []
    @State var selectedSwarm: SwarmExecution?
    
    var body: some View {
        NavigationSplitView {
            List(activeSwarms, selection: $selectedSwarm) { swarm in
                SwarmRow(swarm: swarm)
            }
        } detail: {
            if let swarm = selectedSwarm {
                SwarmDetailView(swarm: swarm)
            } else {
                ContentUnavailableView("Select a Swarm", systemImage: "ant.circle")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Swarm") { createSwarm() }
            }
        }
    }
}

struct SwarmDetailView: View {
    let swarm: SwarmExecution
    
    var body: some View {
        TabView {
            AgentActivityView(swarm: swarm)
                .tabItem { Label("Agents", systemImage: "ant.circle") }
            
            TaskGraphView(swarm: swarm)
                .tabItem { Label("Tasks", systemImage: "chart.xyaxis.line") }
            
            CoordinationBusView(swarm: swarm)
                .tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right") }
            
            ApprovalView(swarm: swarm)
                .tabItem { Label("Approvals", systemImage: "checkmark.shield") }
            
            MonitorView(swarm: swarm)
                .tabItem { Label("Monitor", systemImage: "waveform.path.ecg") }
            
            AuditView(swarm: swarm)
                .tabItem { Label("Audit", systemImage: "doc.text.magnifyingglass") }
        }
    }
}
```

---

## Performance Targets

| Metric | Target |
|--------|--------|
| Swarm Startup | < 5s |
| Agent Spawn | < 2s |
| Message Latency (bus) | < 10ms |
| Consensus (5 agents) | < 30s |
| Sandbox Create (Docker) | < 10s |
| Sandbox Create (Seatbelt) | < 1s |
| Audit Log Append | < 1ms |
| Memory (idle) | < 50 MB |
| Memory (10 agents) | < 500 MB |

---

## Document Version

- **Version**: 1.0
- **Date**: 2026-10-15
- **Status**: Draft for Review