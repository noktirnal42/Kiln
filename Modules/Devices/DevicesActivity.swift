import SwiftUI

extension Activity { static let devices = Activity("devices") }

/// Devices: iOS simulators and Android emulators. Tools are `device_*` (see `DeviceAgentTools`).
enum DevicesActivity {
    static let descriptor = ActivityDescriptor(
        id: "devices", title: "Devices", symbol: "iphone.gen3",
        summary: "iOS simulators and Android emulators: boot, view, install, drive",
        moduleIdentifier: DevicesModule.identifier,
        starterPrompts: { _ in
            [StarterPrompt(title: "What devices do I have?", symbol: "iphone.gen3",
                           text: "List my simulators and emulators, tell me which are running and which tools are missing."),
             StarterPrompt(title: "Look at the screen", symbol: "camera.viewfinder",
                           text: "Take a screenshot of the booted device and describe what is on screen.")]
        },
        toolPrefixes: [DeviceAgentTools.prefix],
        agentPromptSentence: "Use the device_* tools to list, boot and look at iOS simulators and Android emulators (device_screenshot first, then act).",
        capabilities: [
            .tool("device_list", "List devices", .read),
            .tool("device_status", "Device tool status", .read),
            .tool("device_screenshot", "Screenshot a device", .read),
            .tool("device_logs", "Read device logs", .read),
            .tool("device_boot", "Boot a device", .execute),
            .tool("device_shutdown", "Shut down a device", .execute),
            .tool("device_install", "Install an app", .execute),
            .tool("device_launch", "Launch an app", .execute),
            .tool("device_open_url", "Open a URL on a device", .write),
            .tool("device_input", "Tap, type and press keys", .write),
            .tool("device_record_video", "Record the screen", .write),
            .exempt("devices.live-view", "Live screen view", .read,
                    because: "A continuous human view; the agent takes device_screenshot frames on demand."),
        ],
        registerTools: { context in
            guard let devices = await context.module(DevicesModule.identifier, as: DevicesModule.self) else { return }
            DeviceAgentTools.register(service: devices.service, into: context.registry)
        })
}
