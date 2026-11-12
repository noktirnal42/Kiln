import Foundation
import Testing
@testable import Kiln

private func model(_ id: String, _ type: ProviderType, reasons: Bool = true, name: String? = nil) -> ModelDescriptor {
    ModelDescriptor(id: id, name: name ?? id, providerID: type.rawValue, providerType: type, supportsReasoning: reasons)
}

struct ReasoningOptionsTests {
    // MARK: What each model offers

    @Test func aModelThatDoesNotReasonOffersNothingAndSaysWhy() {
        let control = ReasoningCapability.control(for: model("ollama-llama3.2", .ollama, reasons: false, name: "llama3.2"))
        #expect(control == .unavailable("llama3.2 does not offer reasoning options."))
        #expect(!control.isAvailable && control.explanation.contains("does not offer"))
    }

    @Test func ollamaThinkingModelsGetASwitchAndGptOssGetsNamedLevels() {
        #expect(ReasoningCapability.control(for: model("ollama-qwen3:8b", .ollama, name: "qwen3:8b")) == .toggle)
        #expect(ReasoningCapability.control(for: model("ollama-cloud-deepseek-r1", .ollamaCloud, name: "deepseek-r1")) == .toggle)
        let levels = ReasoningCapability.control(for: model("ollama-gpt-oss:20b", .ollama, name: "gpt-oss:20b"))
        #expect(levels == .levels([ReasoningCapability.low, ReasoningCapability.medium, ReasoningCapability.high]))
    }

    @Test func openRouterReasoningModelsGetLowMediumHigh() {
        let control = ReasoningCapability.control(for: model("openrouter-x/y", .openRouter))
        #expect(control == .levels([ReasoningCapability.low, ReasoningCapability.medium, ReasoningCapability.high]))
        #expect(ReasoningCapability.control(for: model("openrouter-x/z", .openRouter, reasons: false)).isAvailable == false)
    }

    @Test func nvidiaGlmOffersTheLevelsKilnAlreadySendsAndOtherNimModelsOfferNone() {
        let glm = ReasoningCapability.control(for: model("nvidia-nim-z-ai/glm-5.3-flash", .nvidiaNIM, name: "GLM 5.3 Flash"))
        #expect(glm == .levels([ReasoningCapability.low, ReasoningCapability.high, ReasoningCapability.max]))
        let other = ReasoningCapability.control(for: model("nvidia-nim-acme/some-reasoning", .nvidiaNIM))
        #expect(!other.isAvailable && other.explanation.contains("NVIDIA does not publish"))
    }

    @Test func customEndpointsAndOnDeviceModelsReportNoReasoningControl() {
        for type in [ProviderType.customEndpoint, .appleFoundation, .applePCC, .mlx] {
            #expect(!ReasoningCapability.control(for: model("x", type)).isAvailable, "\(type)")
        }
    }

    // MARK: Choices

    @Test func theDefaultIsOnForASwitchAndTheMiddleLevelForLevels() {
        #expect(ReasoningCapability.defaultSelection(for: .toggle) == .on)
        #expect(ReasoningCapability.defaultSelection(for: .levels([ReasoningCapability.low, ReasoningCapability.medium, ReasoningCapability.high])) == .level("medium"))
        #expect(ReasoningCapability.defaultSelection(for: .levels([ReasoningCapability.low, ReasoningCapability.high, ReasoningCapability.max])) == .level("high"))
        #expect(ReasoningCapability.defaultSelection(for: .unavailable("no")) == nil)
    }

    @Test func aStoredChoiceThatTheModelNoLongerOffersFallsBackToTheDefault() {
        let levels = ReasoningControl.levels([ReasoningCapability.low, ReasoningCapability.high, ReasoningCapability.max])
        #expect(ReasoningCapability.normalized(.level("max"), for: levels) == .level("max"))
        #expect(ReasoningCapability.normalized(.level("medium"), for: levels) == .level("high"), "this model has no medium")
        #expect(ReasoningCapability.normalized(.off, for: levels) == .level("high"), "a model with levels cannot be switched off from here")
        #expect(ReasoningCapability.normalized(.level("low"), for: .toggle) == .on)
        #expect(ReasoningCapability.normalized(.off, for: .toggle) == .off)
        #expect(ReasoningCapability.normalized(.on, for: .unavailable("no")) == nil)
    }

    @Test func choicesAreRememberedPerModel() throws {
        let store = ReasoningChoiceStore(defaults: nil)
        #expect(store.selection(forModel: "a") == nil)
        store.set(.level("max"), forModel: "a")
        store.set(.off, forModel: "b")
        #expect(store.selection(forModel: "a") == .level("max") && store.selection(forModel: "b") == .off)
        for s in [ReasoningSelection.off, .on, .level("high")] { #expect(ReasoningSelection(storage: s.storage) == s) }
        #expect(ReasoningSelection(storage: "level:") == nil && ReasoningSelection(storage: "nonsense") == nil)
    }

    // MARK: From a choice to the request

    @Test func applyingAChoiceSetsWhatTheProvidersRead() {
        let base = ReasoningConfig.default
        let levels = ReasoningControl.levels([ReasoningCapability.low, ReasoningCapability.medium, ReasoningCapability.high])
        let high = base.applying(.level("high"), control: levels)
        #expect(high.enabled && high.level == "high" && !high.chosenOff)
        let off = base.applying(.off, control: .toggle)
        #expect(!off.enabled && off.chosenOff && off.level == nil)
        let on = base.applying(nil, control: .toggle)
        #expect(on.enabled && !on.chosenOff && on.level == nil)
        let none = base.applying(.level("high"), control: .unavailable("no"))
        #expect(!none.enabled && none.level == nil && !none.chosenOff, "a model with no control never gets reasoning fields")
        #expect(high.temperature == base.temperature && high.topP == base.topP, "other settings are kept")
    }

    @Test func openRouterGetsReasoningEffortForAChosenLevel() throws {
        let request = ChatRequest(messages: [ChatMessage(role: .user, content: "hi")], model: "x/y")
        let withLevel = ReasoningConfig.default.applying(.level("high"), control: .levels([ReasoningCapability.low, ReasoningCapability.medium, ReasoningCapability.high]))
        let body = try JSONSerialization.jsonObject(with: OpenAICompatibleTransport.body(for: request, reasoning: withLevel)) as? [String: Any]
        #expect((body?["reasoning"] as? [String: Any])?["effort"] as? String == "high")
        #expect((body?["reasoning"] as? [String: Any])?["max_tokens"] == nil)
        let plain = try JSONSerialization.jsonObject(with: OpenAICompatibleTransport.body(for: request, reasoning: .default)) as? [String: Any]
        #expect((plain?["reasoning"] as? [String: Any])?["max_tokens"] as? Int == 2048, "without a level the budget is sent as before")
        let off = try JSONSerialization.jsonObject(with: OpenAICompatibleTransport.body(for: request, reasoning: ReasoningConfig.default.applying(nil, control: .unavailable("no")))) as? [String: Any]
        #expect(off?["reasoning"] == nil)
    }

    @Test func nvidiaGlmGetsTheChosenEffort() {
        for level in ["low", "high", "max"] {
            let config = ReasoningConfig.default.applying(.level(level), control: .levels([ReasoningCapability.low, ReasoningCapability.high, ReasoningCapability.max]))
            #expect(NVIDIANIMProvider.requestOptions(model: "z-ai/glm-5.3-flash", reasoning: config)["reasoning_effort"] == ProviderJSON(level))
        }
    }

    @Test func ollamaGetsALevelTrueFalseOrNothing() {
        let levels = ReasoningControl.levels([ReasoningCapability.low, ReasoningCapability.medium, ReasoningCapability.high])
        #expect(OpenCodeProvider.thinkValue(ReasoningConfig.default.applying(.level("low"), control: levels)) == ProviderJSON("low"))
        #expect(OpenCodeProvider.thinkValue(ReasoningConfig.default.applying(.on, control: .toggle)) == ProviderJSON(true))
        #expect(OpenCodeProvider.thinkValue(ReasoningConfig.default.applying(.off, control: .toggle)) == ProviderJSON(false), "an explicit off is sent")
        #expect(OpenCodeProvider.thinkValue(ReasoningConfig.default.applying(nil, control: .unavailable("no"))) == nil, "a model that cannot think never gets the field")
        #expect(OpenCodeProvider.thinkValue(nil) == nil)
    }

    @Test func aConfigSavedBeforeLevelsExistedStillDecodes() throws {
        let old = #"{"enabled":true,"budget":"2048","depth":"3-5","temperature":0.7,"topP":0.95,"maxTokens":4096,"stopSequences":[]}"#
        let config = try JSONDecoder().decode(ReasoningConfig.self, from: Data(old.utf8))
        #expect(config.level == nil && !config.chosenOff && config.enabled)
        let roundTrip = try JSONDecoder().decode(ReasoningConfig.self, from: JSONEncoder().encode(ReasoningConfig.default.applying(.level("high"), control: .levels([ReasoningCapability.high]))))
        #expect(roundTrip.level == "high")
    }
}
