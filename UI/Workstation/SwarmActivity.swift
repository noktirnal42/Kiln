import SwiftUI

extension Activity { static let swarm = Activity("swarm") }

/// Swarm: a goal given to a team of agents working in parallel.
enum SwarmActivity {
    private static let workerOnly = "Bound to one swarm worker's coordination endpoint, so it speaks only as that worker; an outside agent has no worker identity to use it as."

    static let descriptor = ActivityDescriptor(
        id: "swarm", title: "Swarm", symbol: "person.3.sequence",
        summary: "Give a goal to a team of agents working in parallel",
        moduleIdentifier: nil,
        content: .custom { _ in AnyView(SwarmView()) },
        starterPrompts: { hasProject in
            [StarterPrompt(title: "Just ask the agent", symbol: "sparkles", text: "Break this job into steps and do it: ")]
                + StarterPrompts.project(hasProject).prefix(2)
        },
        toolPrefixes: ["swarm_"],
        agentToolPatterns: [],   // Workers get the swarm tools per run; the Workstation Agent does not.
        capabilities: [
            .workerTool("swarm_post", "Post a note to the team", .read, because: workerOnly),
            .workerTool("swarm_read", "Read team messages", .read, because: workerOnly),
            .workerTool("swarm_memory_get", "Read shared team memory", .read, because: workerOnly),
            .workerTool("swarm_memory_set", "Write shared team memory", .read, because: workerOnly),
            .workerTool("swarm_report_blocker", "Report a blocker", .read, because: workerOnly),
            .exempt("swarm.run", "Run a goal with a team", .execute,
                    because: "Gap: no top-level tool yet to create a swarm run; tracked in docs/13 (Swarm row)."),
            .exempt("swarm.stop", "Stop a swarm run", .write,
                    because: "Gap: no top-level tool yet to cancel a swarm run; tracked in docs/13 (Swarm row)."),
            .exempt("swarm.inspect", "Inspect a run's tasks and team channel", .read,
                    because: "Gap: no top-level tool yet to read a run's plan, results or channel; tracked in docs/13 (Swarm row)."),
        ])
}
