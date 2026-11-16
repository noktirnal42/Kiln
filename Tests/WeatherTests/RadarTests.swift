import Foundation
import Testing
@testable import Kiln

struct RadarTests {
    @Test func tileBoundsCoverTheWorldAtZoomZeroAndHalveEachLevel() {
        let world = 20037508.342789244
        let whole = RadarWMS.bounds(x: 0, y: 0, z: 0)
        #expect(abs(whole.0 + world) < 0.001 && abs(whole.1 + world) < 0.001 && abs(whole.2 - world) < 0.001 && abs(whole.3 - world) < 0.001)
        let child = RadarWMS.bounds(x: 1, y: 1, z: 1)   // south-east quarter
        #expect(abs(child.0) < 0.001 && abs(child.3) < 0.001 && abs(child.2 - world) < 0.001 && abs(child.1 + world) < 0.001)
    }

    @Test func tileURLNamesTheLayerProjectionSizeBoxAndTime() {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let url = RadarWMS.tileURL(x: 3, y: 5, z: 4, frame: when)
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(url.host == "opengeo.ncep.noaa.gov")
        #expect(items["layers"] == "conus_bref_qcd" && items["srs"] == "EPSG:3857" && items["transparent"] == "true")
        #expect(items["width"] == "256" && items["height"] == "256" && items["request"] == "GetMap")
        #expect(items["time"] == "2027-01-15T08:00:00Z")
        #expect(items["bbox"]?.split(separator: ",").count == 4)
        #expect(RadarWMS.tileURL(x: 0, y: 0, z: 3, frame: nil).absoluteString.contains("time=") == false)
    }

    @Test func framesAreParsedOldestFirstAndRangesAreNotGuessed() {
        let xml = """
        <Layer><Dimension name="time" default="2026-11-13T03:15:50Z" units="ISO8601">2026-11-13T03:15:50.000Z, 2026-11-13T01:18:04.000Z,2026-11-13T02:00:00Z</Dimension></Layer>
        """
        let frames = RadarWMS.parseFrames(Data(xml.utf8))
        #expect(frames.count == 3)
        #expect(frames == frames.sorted())
        #expect(frames.last == ISO8601DateFormatter().date(from: "2026-11-13T03:15:50Z"))
        let ranged = "<Dimension name=\"time\">2026-11-13T01:00:00Z/2026-11-13T03:00:00Z/PT2M</Dimension>"
        #expect(RadarWMS.parseFrames(Data(ranged.utf8)).isEmpty)
        #expect(RadarWMS.parseFrames(Data("<nothing/>".utf8)).isEmpty)
    }

    @Test func coverageIsTheContiguousUSOnly() {
        #expect(RadarWMS.covers(latitude: 33.45, longitude: -112.07))
        #expect(!RadarWMS.covers(latitude: 51.5, longitude: -0.12))
    }

    @Test func staleFramesAreCalledStale() {
        let now = Date()
        #expect(!RadarFrames(frames: [now.addingTimeInterval(-5 * 60)], fetched: now).isStale(now: now))
        #expect(RadarFrames(frames: [now.addingTimeInterval(-40 * 60)], fetched: now).isStale(now: now))
        #expect(RadarFrames(frames: [], fetched: now).isStale(now: now))
    }

    @Test func theRadarToolIsAnExecuteToolInTheMapsFamily() throws {
        let tool = MapsTool(kind: .radar)
        #expect(tool.spec.name == "maps_radar")
        #expect(tool.spec.permission == .execute)
        #expect(tool.spec.summary.contains("not a forecast"))
    }
}
