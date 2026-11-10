import Foundation
import Testing
@testable import Kiln

@MainActor struct MapsTests {
    @Test func rejectsInvalidCoordinatesAndLayersWithoutChangingState() throws {
        let state = MapsState()
        try state.navigate(latitude: 33, longitude: -112, span: 1)
        #expect(throws: (any Error).self) { try state.navigate(latitude: 91, longitude: 0, span: 1) }
        #expect(throws: (any Error).self) { try state.navigate(latitude: 0, longitude: .nan, span: 1) }
        #expect(throws: (any Error).self) { try state.setLayer("unknown") }
        #expect(state.latitude == 33 && state.longitude == -112 && state.layer == "standard")
        try state.setLayer("usgs_topo")
        #expect(state.layer == "usgs_topo")
    }
    @Test func networkAndMapChangesHaveAppropriateApprovalLevels() {
        #expect(MapsTool(kind: .viewport).spec.permission == .read)
        #expect(MapsTool(kind: .navigate).spec.permission == .write)
        #expect(MapsTool(kind: .set_layer).spec.permission == .write)
        #expect(MapsTool(kind: .search_places).spec.permission == .execute)
        #expect(MapsTool(kind: .search_historical).spec.permission == .execute)
    }
    @Test func decodesHistoricalRecordWithMissingOptionalFields() throws {
        let map = try JSONDecoder().decode(HistoricalMap.self, from: Data(#"{"sourceId":"id","title":"Old map"}"#.utf8))
        #expect(map.id == "id" && map.downloadURL == nil && map.publicationDate == nil)
    }
}
