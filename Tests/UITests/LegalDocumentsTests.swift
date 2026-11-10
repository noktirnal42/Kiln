import Foundation
import Testing
@testable import Kiln

@Suite("Legal documents ship in the app")
struct LegalDocumentsTests {
    @Test func everyLegalTextIsBundled() throws {
        for document in LegalDocument.allCases {
            let text = try #require(document.text(), "\(document.title) is missing from the app bundle")
            #expect(text.count > 200, "\(document.title) looks empty")
        }
    }

    @Test func licenseNamesTheLicenseAndTheLicensor() throws {
        let license = try #require(LegalDocument.license.text())
        #expect(license.contains("PolyForm Noncommercial License 1.0.0"))
        #expect(license.contains("Required Notice: Copyright (c) 2026 FreeRange Labs"))
    }

    @Test func noticesCoverTheDependenciesTheAppLinks() throws {
        let notices = try #require(LegalDocument.notices.text())
        for name in ["mlx-swift", "SwiftTerm", "swift-huggingface", "swift-transformers", "yyjson"] {
            #expect(notices.contains(name), "\(name) is missing from THIRD-PARTY-NOTICES.md")
        }
    }
}
