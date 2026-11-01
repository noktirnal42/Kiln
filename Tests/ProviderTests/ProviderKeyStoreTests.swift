import Foundation
import Testing
@testable import Kiln

struct ProviderKeyStoreTests {
    /// A throwaway keychain namespace, so tests never touch the user's real provider keys.
    private func store() -> (ProviderKeyStore, String) {
        let module = "com.kiln.tests.\(UUID().uuidString)"
        return (ProviderKeyStore(module: module), module)
    }

    @Test func keysAreTrimmedAndRefusedWhenEmptyOrMalformed() throws {
        #expect(try ProviderKeyStore.clean("  sk-or-abc123\n") == "sk-or-abc123")
        #expect(throws: ProviderKeyError.empty) { try ProviderKeyStore.clean("   ") }
        #expect(throws: ProviderKeyError.containsWhitespace) { try ProviderKeyStore.clean("sk or abc") }
        #expect(throws: ProviderKeyError.tooLong) { try ProviderKeyStore.clean(String(repeating: "a", count: 513)) }
    }

    @Test func aSavedKeyReportsOnlyThatItExistsAndItsLastFour() throws {
        let (store, _) = store()
        defer { try? store.remove("openrouter") }
        #expect(!store.hasKey("openrouter"))
        try store.save("  sk-or-v1-abcdef1234 ", for: "openrouter")
        #expect(store.hasKey("openrouter"))
        #expect(store.lastFour("openrouter") == "1234")
    }

    @Test func savingAgainReplacesAndRemovingDeletes() throws {
        let (store, _) = store()
        defer { try? store.remove("nvidia-nim") }
        try store.save("nvapi-first0001", for: "nvidia-nim")
        try store.save("nvapi-second0002", for: "nvidia-nim")
        #expect(store.lastFour("nvidia-nim") == "0002")
        try store.remove("nvidia-nim")
        #expect(!store.hasKey("nvidia-nim"))
        try store.remove("nvidia-nim")   // removing what is not there is not an error
    }

    @Test func theCatalogLinksEachHostedProviderToItsKeyPage() {
        let byID = Dictionary(uniqueKeysWithValues: ProviderKeyEntry.all.map { ($0.id, $0) })
        #expect(byID["openrouter"]?.keysPage?.host == "openrouter.ai")
        #expect(byID["nvidia-nim"]?.keysPage?.host == "build.nvidia.com")
        #expect(byID["ollama-cloud"]?.keysPage?.host == "ollama.com")
        #expect(byID["custom"]?.keysPage == nil)
        #expect(byID["custom"]?.needsBaseURL == true)
        #expect(Set(byID.keys).isSuperset(of: ["openrouter", "nvidia-nim", "ollama-cloud"]))
    }
}

@MainActor
struct ProviderSettingsModelTests {
    @Test func aBadDraftShowsAnErrorAndStoresNothing() {
        let model = ProviderSettingsModel(store: ProviderKeyStore(module: "com.kiln.tests.\(UUID().uuidString)"))
        model.setDraft("has spaces", for: "openrouter")
        #expect(model.save("openrouter") == false)
        #expect(model.rows["openrouter"]?.isError == true)
        #expect(model.rows["openrouter"]?.stored == false)
    }

    @Test func aGoodDraftIsStoredAndClearedFromTheField() {
        let model = ProviderSettingsModel(store: ProviderKeyStore(module: "com.kiln.tests.\(UUID().uuidString)"))
        defer { model.remove("openrouter") }
        model.setDraft("sk-or-secret9876", for: "openrouter")
        #expect(model.save("openrouter"))
        #expect(model.rows["openrouter"]?.draft == "")
        #expect(model.rows["openrouter"]?.stored == true)
        #expect(model.rows["openrouter"]?.lastFour == "9876")
    }
}
