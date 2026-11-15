import CoreLocation
import Foundation

/// Where the Mac is, for answers that depend on it (the weather here,
/// what is nearby). Off until the user turns it on in Settings, and macOS
/// asks for permission the first time. The location is used for the lookup
/// and the answer; it is not stored.
@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    struct Place: Sendable, Equatable {
        let latitude: Double
        let longitude: Double
        /// "Jersey City, New Jersey" when the name is known.
        let name: String
        let at: Date

        var label: String {
            name.isEmpty ? String(format: "%.3f, %.3f", latitude, longitude) : name
        }
    }

    /// The last known place.
    @Published private(set) var place: Place?
    /// Why there is no place, in words for Settings; "" when all is well.
    @Published private(set) var problem = ""

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var asking = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var enabled: Bool { AppSettings.shared.useLocation }

    /// Asks macOS for permission if it has not been given, and for a fix.
    func refresh() {
        guard enabled else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            problem = "Location is off for Companion in System Settings > Privacy & Security > Location Services."
        default:
            problem = ""
            guard !asking else { return }
            asking = true
            manager.requestLocation()
        }
    }

    /// The place now: the last one if it is recent, otherwise a fresh fix,
    /// waited for briefly. nil when location is off or cannot be had.
    func current() async -> Place? {
        guard enabled else { return nil }
        if let place, Date().timeIntervalSince(place.at) < 600 { return place }
        refresh()
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let place, Date().timeIntervalSince(place.at) < 600 { return place }
            if !problem.isEmpty { break }
        }
        // An older fix is still better than none.
        return place
    }

    private func took(latitude: Double, longitude: Double) {
        asking = false
        problem = ""
        let previous = place?.name ?? ""
        place = Place(latitude: latitude, longitude: longitude, name: previous, at: Date())
        let location = CLLocation(latitude: latitude, longitude: longitude)
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(location) { [weak self] marks, _ in
            let mark = marks?.first
            let name = [mark?.locality, mark?.administrativeArea].compactMap { $0 }.joined(separator: ", ")
            Task { @MainActor in
                guard let self, !name.isEmpty else { return }
                self.place = Place(latitude: latitude, longitude: longitude, name: name, at: Date())
            }
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.refresh() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        let latitude = coordinate.latitude
        let longitude = coordinate.longitude
        Task { @MainActor in self.took(latitude: latitude, longitude: longitude) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        Task { @MainActor in
            self.asking = false
            self.problem = denied
                ? "Location is off for Companion in System Settings > Privacy & Security > Location Services."
                : "The Mac could not work out where it is just now."
        }
    }
}
