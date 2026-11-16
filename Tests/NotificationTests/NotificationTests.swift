import Foundation
import Testing
@testable import Kiln

@MainActor
final class FakePoster: NotificationPosting {
    var status: NotificationAuthorization = .allowed
    var grantsOnRequest = true
    private(set) var requests = 0
    private(set) var posted: [OutgoingNotification] = []
    private(set) var removed: [String] = []
    func authorization() async -> NotificationAuthorization { status }
    func requestAuthorization() async -> Bool { requests += 1; status = grantsOnRequest ? .allowed : .denied; return grantsOnRequest }
    func post(_ notification: OutgoingNotification) async -> Bool { posted.append(notification); return true }
    func deliveredCount() async -> Int { posted.count }
    func remove(ids: [String]) { removed += ids }
}

@MainActor
final class FakeFocus: FocusStatusProviding {
    var current: UserFocusState = .notFocused
    func state() async -> UserFocusState { current }
    func requestAuthorization() async -> UserFocusState { current }
}

private let defaults = NotificationPreferences()

struct NotificationPolicyTests {
    @Test func anApprovalIsSentWhenKilnIsInTheBackgroundEvenInFocus() {
        #expect(NotificationPolicy.decide(.approval, appIsActive: false, focus: .notFocused, preferences: defaults) == .post(.active))
        #expect(NotificationPolicy.decide(.approval, appIsActive: false, focus: .focused, preferences: defaults) == .post(.active), "the system's own Focus filter decides")
        #expect(NotificationPolicy.decide(.approval, appIsActive: true, focus: .notFocused, preferences: defaults) == .hold("Kiln is in front."))
    }

    @Test func aFinishedRunNeedsTheBackgroundALongRunAndNoFocus() {
        func run(_ seconds: Double, active: Bool = false, focus: UserFocusState = .notFocused, _ p: NotificationPreferences = defaults) -> NotificationDecision {
            NotificationPolicy.decide(.runFinished(.completed, seconds: seconds), appIsActive: active, focus: focus, preferences: p)
        }
        #expect(run(120) == .post(.active))
        #expect(run(120, active: true) == .hold("Kiln is in front."))
        #expect(run(5) == .hold("The run was short."))
        #expect(run(120, focus: .focused) == .hold("Focus is on."))
        var loud = defaults; loud.quietDuringFocus = false
        #expect(run(120, focus: .focused, loud) == .post(.active))
        var impatient = defaults; impatient.minimumRunSeconds = 0
        #expect(run(1, impatient) == .post(.active))
        #expect(run(120, focus: .unknown) == .post(.active), "an unknown Focus does not silence a notice")
        #expect(run(120, focus: .notAuthorized) == .post(.active))
    }

    @Test func everyKindCanBeTurnedOff() {
        var off = defaults; off.approvals = false; off.runFinished = false; off.scheduledTasks = false; off.agentMessages = false
        for event in [NotificationEvent.approval, .runFinished(.failed, seconds: 999), .scheduledTaskFinished, .agentMessage] {
            guard case .hold(let reason) = NotificationPolicy.decide(event, appIsActive: false, focus: .notFocused, preferences: off) else { Issue.record("\(event) was not held"); continue }
            #expect(reason.contains("turned off"))
        }
    }

    @Test func aScheduledTaskAndAnAgentMessageWaitOutFocusAndAnAgentMessageAlsoWaitsForTheBackground() {
        #expect(NotificationPolicy.decide(.scheduledTaskFinished, appIsActive: true, focus: .notFocused, preferences: defaults) == .post(.active), "a scheduled task finishes whether or not Kiln is in front")
        #expect(NotificationPolicy.decide(.scheduledTaskFinished, appIsActive: false, focus: .focused, preferences: defaults) == .hold("Focus is on."))
        #expect(NotificationPolicy.decide(.agentMessage, appIsActive: true, focus: .notFocused, preferences: defaults) != .post(.active))
        #expect(NotificationPolicy.decide(.agentMessage, appIsActive: false, focus: .focused, preferences: defaults) == .hold("Focus is on."))
        #expect(NotificationPolicy.decide(.agentMessage, appIsActive: false, focus: .notFocused, preferences: defaults, urgency: .passive) == .post(.passive))
    }

    @Test func preferencesRoundTripAndOlderOnesDecode() throws {
        let store = NotificationPreferenceStore(defaults: nil)
        #expect(store.preferences == defaults)
        var changed = defaults; changed.runFinished = false; changed.minimumRunSeconds = 90
        store.preferences = changed
        #expect(store.preferences == changed)
        let decoded = try JSONDecoder().decode(NotificationPreferences.self, from: JSONEncoder().encode(changed))
        #expect(decoded == changed)
    }
}

@MainActor
struct NotificationCoordinatorTests {
    private func make(active: Bool = false, now: @escaping () -> Date = Date.init) -> (NotificationCoordinator, FakePoster, FakeFocus) {
        let poster = FakePoster(), focus = FakeFocus()
        return (NotificationCoordinator(preferenceStore: NotificationPreferenceStore(defaults: nil), poster: poster, focus: focus, isAppActive: { active }, now: now), poster, focus)
    }

    @Test func aNoticeIsPostedWhenTheRulesAllowIt() async {
        let (c, poster, _) = make()
        let result = await c.deliver(.approval, title: "Kiln needs your approval", body: "chat: the agent wants to use run_command.", id: "kiln.approval")
        #expect(result == .sent)
        #expect(poster.posted == [OutgoingNotification(id: "kiln.approval", title: "Kiln needs your approval", body: "chat: the agent wants to use run_command.", level: .active)])
    }

    @Test func nothingIsPostedWhenTheRulesHoldIt() async {
        let (c, poster, focus) = make(active: true)
        #expect(await c.deliver(.approval, title: "t", body: "b") == .held("Kiln is in front."))
        let (d, poster2, focus2) = make()
        focus2.current = .focused
        #expect(await d.deliver(.scheduledTaskFinished, title: "t", body: "b") == .held("Focus is on."))
        #expect(poster.posted.isEmpty && poster2.posted.isEmpty); _ = focus
    }

    @Test func permissionIsAskedOnlyWhenANoticeWouldGoOutAndADeniedSystemIsReported() async {
        let (c, poster, _) = make()
        poster.status = .notDetermined
        #expect(await c.deliver(.approval, title: "t", body: "b") == .sent)
        #expect(poster.requests == 1)
        let (d, denied, _) = make()
        denied.status = .notDetermined; denied.grantsOnRequest = false
        #expect(await d.deliver(.approval, title: "t", body: "b") == .notAllowed)
        #expect(denied.posted.isEmpty)
        let (e, quiet, _) = make(active: true)
        quiet.status = .notDetermined
        _ = await e.deliver(.approval, title: "t", body: "b")
        #expect(quiet.requests == 0, "a held notice never triggers the macOS permission prompt")
    }

    @Test func theAgentCanSendFiveNoticesInTenMinutes() async {
        nonisolated(unsafe) var clock = Date(timeIntervalSince1970: 1_000_000)
        let (c, poster, _) = make(now: { clock })
        for _ in 0..<NotificationCoordinator.agentLimit { #expect(await c.deliver(.agentMessage, title: "t", body: "b") == .sent) }
        #expect(await c.deliver(.agentMessage, title: "t", body: "b") == .rateLimited)
        #expect(poster.posted.count == NotificationCoordinator.agentLimit)
        clock = clock.addingTimeInterval(NotificationCoordinator.agentWindow + 1)
        #expect(await c.deliver(.agentMessage, title: "t", body: "b") == .sent, "the window moves on")
        #expect(await c.deliver(.approval, title: "t", body: "b") == .sent, "approvals are not counted against the agent's limit")
    }

    @Test func clearingTheApprovalNoticeRemovesIt() {
        let (c, poster, _) = make()
        c.clearApprovalNotice()
        #expect(poster.removed == ["kiln.approval"])
    }
}

@MainActor
struct NotificationToolTests {
    private let context = ToolExecutionContext(workspaceRoot: nil, conversationID: UUID())

    private func tool(_ kind: NotificationTool.Kind, active: Bool = false) -> (NotificationTool, FakePoster) {
        let poster = FakePoster()
        let coordinator = NotificationCoordinator(preferenceStore: NotificationPreferenceStore(defaults: nil), poster: poster, focus: FakeFocus(), isAppActive: { active })
        return (NotificationTool(kind: kind, coordinator: { coordinator }), poster)
    }

    @Test func aNoticeFromTheAgentIsLabelledCleanedAndClipped() async throws {
        let (notify, poster) = tool(.notify)
        let long = String(repeating: "x", count: 500)
        let result = try await notify.execute(argumentsJSON: #"{"title":"Build\nis   done\u0007","body":"\#(long)","urgency":"quiet"}"#, context: context)
        #expect(result == "Sent.")
        let sent = try #require(poster.posted.first)
        #expect(sent.title == "Kiln agent: Build is done", "a control character and a line break become one space, and the agent cannot pose as a system alert")
        #expect(sent.body.count == 300 && sent.body.hasSuffix("…"))
        #expect(sent.level == .passive)
    }

    @Test func aHeldNoticeSaysWhyAndAMissingTitleIsRefused() async throws {
        let (notify, poster) = tool(.notify, active: true)
        let result = try await notify.execute(argumentsJSON: #"{"title":"Done","body":"x"}"#, context: context)
        #expect(result.hasPrefix("Not sent as a system notification:") && poster.posted.isEmpty)
        await #expect(throws: (any Error).self) { _ = try await notify.execute(argumentsJSON: #"{"title":"  ","body":"x"}"#, context: context) }
    }

    @Test func theStatusToolReportsPermissionFocusAndSettings() async throws {
        let (status, _) = tool(.status)
        let text = try await status.execute(argumentsJSON: "{}", context: context)
        #expect(text.contains("System notifications: allowed") && text.contains("Focus is off") && text.contains("approvals yes"))
    }

    @Test func theToolsHaveTheRightTiersAndNames() {
        let (notify, _) = tool(.notify), (status, _) = tool(.status)
        #expect(notify.spec.name == "notify_user" && notify.spec.permission == .write)
        #expect(status.spec.name == "notifications_status" && status.spec.permission == .read)
        #expect(NotificationTool.plain("a\u{0}b\tc  d", limit: 20) == "a b c d")
    }

    @Test func focusStatesAreDescribedHonestly() {
        #expect(NotificationTool.describe(.focused) == "Focus is on")
        #expect(NotificationTool.describe(.notFocused).contains("Communication Notifications"))
        #expect(NotificationTool.describe(.notAuthorized).contains("not been allowed"))
    }
}
