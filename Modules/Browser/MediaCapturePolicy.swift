import Foundation
import WebKit

/// What the browser does when a page asks for the microphone, camera or screen. Kiln declares the microphone entitlement (voice
/// chat in a page needs it) but not the camera, and never lets a page share the screen; the microphone is always the person's choice.
enum MediaCaptureDecision: Equatable { case ask(String), deny(String) }

enum MediaCapturePolicy {
    static func decide(type: WKMediaCaptureType, host: String) -> MediaCaptureDecision {
        let site = host.isEmpty ? "This page" : host
        switch type {
        case .microphone: return .ask("Allow \(site) to use your microphone? It can listen while the page is open. macOS may then ask Kiln for microphone access.")
        case .camera: return .deny("Kiln does not have camera access, so \(site) cannot use the camera.")
        case .cameraAndMicrophone: return .deny("Kiln does not have camera access, so \(site) cannot use the camera and microphone together.")
        @unknown default: return .deny("Kiln does not allow \(site) to use that device.")
        }
    }
}
