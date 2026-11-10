import SwiftUI
import MapKit

struct MapsView: View {
    @State private var state = MapsState.shared
    @State private var location = MapsLocation.shared
    @State private var showDirections = false
    @State private var destination = ""
    @State private var directionText = ""
    @State private var routing = false
    var body: some View {
        VStack(spacing: 0) {
            SSActivityHeader(title: "Maps", subtitle: "Explore places and USGS maps", symbol: "map", trailing: { EmptyView() })
            ScrollView(.horizontal) {
              HStack(spacing: 8) {
                TextField("Search a place or address", text: $state.query).textFieldStyle(.roundedBorder).frame(width: 240)
                    .onSubmit { search() }
                Button("Search", action: search).disabled(state.busy || state.query.isEmpty)
                Button("Directions…") { showDirections = true }
                Picker("Map layer", selection: $state.layer) {
                    Text("Map").tag("standard"); Text("Satellite").tag("satellite"); Text("Hybrid").tag("hybrid"); Text("Terrain").tag("terrain"); Text("USGS Topo").tag("usgs_topo")
                }.fixedSize()
                if state.route != nil { Button("Clear route") { state.route = nil; state.routeRevision += 1 } }
                if !state.pins.isEmpty { Menu("Pins") { ForEach(state.pins) { pin in Button("Remove \(pin.name)") { state.pins.removeAll { $0.id == pin.id }; state.routeRevision += 1 } } } }
                Button("Pin center") { try? state.addPin(name: "Pin \(state.pins.count + 1)", latitude: state.latitude, longitude: state.longitude) }
                Button { location.request() } label: { Label("My Location", systemImage: "location") }.help("Request your location from macOS")
                Button("Historical maps") { historical() }.disabled(state.busy)
              }.fixedSize(horizontal: true, vertical: false).padding(10)
            }
            HStack(spacing: 0) {
                MapCanvas(state: state).frame(maxWidth: .infinity, maxHeight: .infinity)
                if !state.placeResults.isEmpty {
                    Divider()
                    VStack(alignment: .leading) {
                        HStack { Text("Places").font(.headline); Spacer(); Button("Close") { state.placeResults = [] } }
                        List(state.placeResults) { place in
                            Button { try? state.navigate(latitude: place.latitude, longitude: place.longitude, span: 0.15); state.placeResults = [] } label: {
                                VStack(alignment: .leading) { Text(place.name); Text(String(format: "%.4f, %.4f", place.latitude, place.longitude)).font(.caption).foregroundStyle(.secondary) }
                            }.buttonStyle(.plain)
                            Button("Directions from map center") {
                                state.busy = true
                                Task { defer { state.busy = false }; do { state.message = try await state.directions(latitude: place.latitude, longitude: place.longitude) } catch { state.message = error.localizedDescription } }
                            }.font(.caption)
                        }.listStyle(.plain)
                    }.padding(10).frame(width: 250)
                }
                if !state.historical.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("Historical maps").font(.headline); Spacer(); Button("Close") { state.historical = [] } }
                        Text("USGS records for the searched area. Open a source to view or download it.").font(.caption).foregroundStyle(.secondary)
                        List(state.historical) { map in
                            VStack(alignment: .leading) {
                                Text(map.title).font(.callout)
                                Text("\(map.publicationDate ?? "Date unknown") · \(map.format ?? "Format unknown")").font(.caption).foregroundStyle(.secondary)
                                if let url = map.downloadURL { Link("Open map", destination: url) }
                                if let url = map.metaUrl { Link("Source details", destination: url) }
                            }.padding(.vertical, 3)
                        }.listStyle(.plain)
                    }.padding(10).frame(width: 300)
                }
            }
            HStack {
                Text(String(format: "%.5f, %.5f", state.latitude, state.longitude)).monospacedDigit()
                Text(state.layer == "usgs_topo" ? "USGS The National Map · USGS Topo" : "Map data © Apple")
                Spacer()
                if state.busy { ProgressView().controlSize(.small) }
                if let message = state.message { Text(message).lineLimit(2) }
                else if location.message != "Location has not been requested." { Text(location.message).lineLimit(1) }
            }.font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .sheet(isPresented: $showDirections) {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("Driving directions").font(.headline); Spacer(); Button("Done") { showDirections = false }.keyboardShortcut(.cancelAction) }
                Text("Starting point: the current map center. Search for a destination below.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Destination or address", text: $destination).textFieldStyle(.roundedBorder)
                    Button(routing ? "Finding…" : "Get directions") { calculateDirections() }.disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || routing)
                }
                if routing { ProgressView() }
                ScrollView { Text(directionText.isEmpty ? "The route and its turn-by-turn instructions will appear here." : directionText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.padding(16).frame(width: 560, height: 400)
        }
    }
    private func calculateDirections() {
        routing = true
        directionText = ""
        Task {
            defer { routing = false }
            do {
                let places = try await state.places(destination)
                guard let place = places.first else { directionText = "No destination found. Try a more specific address."; return }
                directionText = "Destination: \(place.name) (\(place.latitude), \(place.longitude))\n\n" + (try await state.directions(latitude: place.latitude, longitude: place.longitude))
            } catch { directionText = error.localizedDescription }
        }
    }
    private func search() {
        state.busy = true; state.message = nil
        Task { defer { state.busy = false }; do {
            let results = try await state.places(state.query)
            state.placeResults = results; state.historical = []
            state.message = results.isEmpty ? "No places found." : nil
        } catch { state.message = error.localizedDescription } }
    }
    private func historical() {
        state.busy = true; state.message = nil
        Task { defer { state.busy = false }; do { let records = try await state.searchHistorical(); state.placeResults = []; if records.isEmpty { state.message = "No historical maps found for this area." } } catch { state.message = error.localizedDescription } }
    }
}

struct MapCanvas: NSViewRepresentable {
    let state: MapsState
    func makeCoordinator() -> Coordinator { Coordinator(state: state) }
    func makeNSView(context: Context) -> MKMapView {
        let view = ContextMapView(); view.state = state; view.delegate = context.coordinator
        view.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: state.latitude, longitude: state.longitude), span: MKCoordinateSpan(latitudeDelta: state.latitudeSpan, longitudeDelta: state.longitudeSpan)), animated: false)
        return view
    }
    func updateNSView(_ view: MKMapView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.revision != state.revision {
            coordinator.revision = state.revision
            view.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: state.latitude, longitude: state.longitude), span: MKCoordinateSpan(latitudeDelta: state.latitudeSpan, longitudeDelta: state.longitudeSpan)), animated: true)
        }
        if coordinator.routeRevision != state.routeRevision {
            coordinator.routeRevision = state.routeRevision
            view.removeAnnotations(view.annotations)
            for pin in state.pins { let point = MKPointAnnotation(); point.title = pin.name; point.coordinate = CLLocationCoordinate2D(latitude: pin.latitude, longitude: pin.longitude); view.addAnnotation(point) }
            if let old = coordinator.routeOverlay { view.removeOverlay(old) }
            coordinator.routeOverlay = state.route?.polyline
            if let line = coordinator.routeOverlay { view.addOverlay(line); view.setVisibleMapRect(line.boundingMapRect, edgePadding: NSEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), animated: true) }
        }
        if coordinator.layer != state.layer {
            coordinator.layer = state.layer
            view.removeOverlays(view.overlays.filter { $0 is MKTileOverlay })
            switch state.layer {
            case "satellite": view.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
            case "hybrid": view.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .flat)
            case "terrain": view.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
            default: view.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
            }
            if state.layer == "usgs_topo" {
                let overlay = MKTileOverlay(urlTemplate: "https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}")
                overlay.canReplaceMapContent = true; view.addOverlay(overlay, level: .aboveLabels)
            }
        }
    }
    final class Coordinator: NSObject, MKMapViewDelegate {
        let state: MapsState
        var revision = 0
        var routeRevision = 0
        var routeOverlay: MKPolyline?
        var layer = ""
        init(state: MapsState) { self.state = state }
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region
            state.latitude = region.center.latitude; state.longitude = region.center.longitude
            state.latitudeSpan = region.span.latitudeDelta; state.longitudeSpan = region.span.longitudeDelta
        }
        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? MKPolyline { let renderer = MKPolylineRenderer(polyline: line); renderer.strokeColor = .systemBlue; renderer.lineWidth = 5; return renderer }
            if let tiles = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tiles) }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

/// AppKit supplies the click position for a native context menu on the map.
final class ContextMapView: MKMapView {
    weak var state: MapsState?
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let coordinate = convert(point, toCoordinateFrom: self)
        let menu = NSMenu()
        let item = NSMenuItem(title: "Drop Pin Here", action: #selector(dropPin(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = [coordinate.latitude, coordinate.longitude]
        menu.addItem(item)
        return menu
    }
    @objc private func dropPin(_ sender: NSMenuItem) {
        guard let coordinates = sender.representedObject as? [Double], coordinates.count == 2, let state else { return }
        try? state.addPin(name: "Pin \(state.pins.count + 1)", latitude: coordinates[0], longitude: coordinates[1])
    }
}
