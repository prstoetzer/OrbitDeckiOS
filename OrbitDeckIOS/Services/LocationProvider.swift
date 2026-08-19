@preconcurrency import CoreLocation
import Combine
import Foundation

@MainActor
final class LocationProvider: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
     @Published var location: CLLocation?
     @Published var errorMessage: String?
     @Published var heading: Double?

    private let manager = CLLocationManager()

    // Continuous location updates have two independent consumers: the compass
    // (which needs fixes to resolve TRUE heading) and the "current location"
    // observer follow. Track each so releasing one doesn't cut updates the other
    // still needs.
    private var headingActive = false
    private var following = false

    func startHeading() {
        guard CLLocationManager.headingAvailable() else { return }
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        // Location updates are required for CoreLocation to resolve TRUE heading
        // (magnetic declination). Satellite azimuths are true-north referenced,
        // so without this the compass reads off by the local declination.
        headingActive = true
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    func stopHeading() {
        headingActive = false
        manager.stopUpdatingHeading()
        if !following { manager.stopUpdatingLocation() }
    }

    /// Continuously follow the device so observer-relative screens track a moving
    /// operator, rather than freezing on the launch/foreground fix. Used by the
    /// "current location" mode in place of one-shot `requestLocation()`.
    func startFollowing() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            following = true
            manager.startUpdatingLocation()
        case .denied, .restricted:
            errorMessage = "Location access is disabled. Enter a station location manually or enable access in Settings."
        @unknown default:
            break
        }
    }

    func stopFollowing() {
        following = false
        if !headingActive { manager.stopUpdatingLocation() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // Prefer true heading; fall back to magnetic until a location fix arrives.
        if newHeading.trueHeading >= 0 {
            heading = newHeading.trueHeading
        } else if newHeading.magneticHeading >= 0 {
            heading = newHeading.magneticHeading
        }
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        // The observer site only matters at ~100 m scale, so avoid recomputing every
        // screen on tiny GPS jitter while still following a genuinely moving operator.
        manager.distanceFilter = 50
    }

    func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            errorMessage = "Location access is disabled. Enter a station location manually or enable access in Settings."
        @unknown default:
            break
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways ||
            manager.authorizationStatus == .authorizedWhenInUse {
            // Resume the follow that was pending authorization; otherwise honour the
            // one-shot fill requested via requestLocation().
            if following { manager.startUpdatingLocation() } else { manager.requestLocation() }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let value = locations.last else { return }
        location = value
        errorMessage = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        errorMessage = error.localizedDescription
    }
}
