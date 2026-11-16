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

    @Test func gpxRoundTripsWaypointsAndTracksAndEscapesNames() throws {
        let xml = GPX.encode(waypoints: [GPXPoint(name: "Tom & Jerry <cafe>", latitude: 33.4, longitude: -112.1)],
                             track: [GPXPoint(name: nil, latitude: 33.4, longitude: -112.1), GPXPoint(name: nil, latitude: 33.5, longitude: -112.2)])
        let doc = try GPX.parse(Data(xml.utf8))
        #expect(doc.waypoints == [GPXPoint(name: "Tom & Jerry <cafe>", latitude: 33.4, longitude: -112.1)])
        #expect(doc.tracks.first?.count == 2 && doc.routes.isEmpty)
    }

    @Test func gpxRoutesAndBadInputAreHandled() throws {
        let route = #"<gpx><rte><rtept lat="1" lon="2"/><rtept lat="3" lon="4"/></rte></gpx>"#
        #expect(try GPX.parse(Data(route.utf8)).routes.first?.count == 2)
        #expect(throws: (any Error).self) { try GPX.parse(Data("not xml".utf8)) }
        #expect(throws: (any Error).self) { try GPX.parse(Data(#"<gpx><wpt lat="95" lon="0"/></gpx>"#.utf8)) }
        #expect(throws: (any Error).self) { try GPX.parse(Data(#"<other/>"#.utf8)) }
        #expect(throws: (any Error).self) { try GPX.parse(Data(count: GPX.maxBytes + 1)) }
    }

    @Test func importingGPXAddsPinsAndDrawsTheTrack() throws {
        let state = MapsState()
        let xml = GPX.encode(waypoints: [GPXPoint(name: "Start", latitude: 34, longitude: -111)], track: [GPXPoint(name: nil, latitude: 34, longitude: -111), GPXPoint(name: nil, latitude: 34.1, longitude: -111.1)])
        let message = try state.importGPX(Data(xml.utf8))
        #expect(state.pins.map(\.name) == ["Start"] && state.track.count == 2)
        #expect(message.contains("1 waypoints"))
        #expect(state.latitude == 34)
        #expect(try GPX.parse(Data(state.exportGPX().utf8)).waypoints.count == 1)
    }

    @Test func routeSummariesReadWithDistanceDurationAndArrival() {
        let start = Date(timeIntervalSince1970: 0)
        let a = RouteSummary(name: "I-10", meters: 23_400, seconds: 24 * 60, steps: ["Head north", "", "Turn left"])
        let b = RouteSummary(name: "", meters: 800, seconds: 3 * 3600 + 120, steps: [])
        #expect(a.distanceText == "23.4 km" && b.distanceText == "800 m")
        #expect(a.durationText == "24 min" && b.durationText == "3 h 2 min")
        let text = RouteSummary.describe([a, b], mode: "driving", start: start)
        #expect(text.contains("Route 1 via I-10: 23.4 km, 24 min, arrive"))
        #expect(text.contains("Head north → Turn left") && text.contains("Route 2: 800 m"))
        #expect(RouteSummary.describe([a], mode: "walking", start: start).hasPrefix("Walking: 23.4 km"))
    }

    @Test func toolsAreHonestAboutWhatMapKitCannotDo() async {
        await #expect(throws: (any Error).self) { try await MapsTool(kind: .offline_download).execute(argumentsJSON: "{}", context: ToolExecutionContext(workspaceRoot: nil, conversationID: UUID())) }
        #expect(MapsTool.mode("transit") == .transit && MapsTool.mode("walking") == .walking && MapsTool.mode(nil) == .automobile)
        #expect(MapsTool(kind: .offline_download).spec.permission == .read)
    }

    @Test func exportRefusesToOverwriteAndNeedsAGPXName() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-gpx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("out.gpx")
        let tool = MapsTool(kind: .export_gpx)
        _ = try await tool.execute(argumentsJSON: #"{"file_path":"\#(file.path)"}"#, context: ToolExecutionContext(workspaceRoot: nil, conversationID: UUID()))
        #expect(FileManager.default.fileExists(atPath: file.path))
        await #expect(throws: (any Error).self) { try await tool.execute(argumentsJSON: #"{"file_path":"\#(file.path)"}"#, context: ToolExecutionContext(workspaceRoot: nil, conversationID: UUID())) }
        await #expect(throws: (any Error).self) { try await tool.execute(argumentsJSON: #"{"file_path":"\#(folder.path)/x.txt"}"#, context: ToolExecutionContext(workspaceRoot: nil, conversationID: UUID())) }
    }
}
