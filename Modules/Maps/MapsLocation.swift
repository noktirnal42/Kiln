import CoreLocation
import Foundation
import Observation

/// One-shot location. The system permission prompt is triggered only by the explicit Maps button.
@MainActor @Observable final class MapsLocation: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = MapsLocation()
    private let manager = CLLocationManager()
    private(set) var location: CLLocation?
    private(set) var message = "Location has not been requested."
    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyHundredMeters }
    func request() {
        switch manager.authorizationStatus {
        case .denied, .restricted: message = "Location is unavailable. Enable it for Kiln in macOS Privacy & Security settings."
        case .notDetermined:
            // macOS only shows the permission prompt after an explicit authorization request.
            message = "Waiting for your answer to the macOS location prompt…"; manager.requestWhenInUseAuthorization()
        default: message = "Finding your location…"; manager.requestLocation()
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: if location == nil { message = "Finding your location…"; manager.requestLocation() }
        case .denied, .restricted: message = "Location is unavailable. Enable it for Kiln in macOS Privacy & Security settings."
        default: break
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last, latest.horizontalAccuracy >= 0 else { return }
        location = latest; message = "Location updated."
        try? MapsState.shared.navigate(latitude: latest.coordinate.latitude, longitude: latest.coordinate.longitude, span: 0.05)
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied {
            message = "Location denied. Enable Location Services for Kiln in System Settings → Privacy & Security → Location Services."
        } else { message = "Could not get location: \(error.localizedDescription)" }
    }
}
