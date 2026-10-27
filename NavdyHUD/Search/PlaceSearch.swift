import Combine
import CoreLocation
import Foundation
import MapKit
import NavdyPlaces

/// Where the HUD should drive to. Coordinates are what the HUD routes on; name/address are labels.
struct Destination: Equatable {
    var name: String
    var address: String?
    var latitude: Double
    var longitude: Double
}

extension Destination {
    init(_ item: MKMapItem) {
        let c = item.placemark.coordinate
        self.init(name: item.name ?? "目的地", address: item.placemark.title, latitude: c.latitude, longitude: c.longitude)
    }
}

enum SearchProvider: String, CaseIterable, Identifiable {
    case google, apple
    var id: String { rawValue }
    var title: String { self == .google ? "Google 地圖" : "Apple 地圖" }
}

struct Suggestion: Identifiable {
    enum Source {
        case google(GooglePlaces.Prediction)
        case apple(MKLocalSearchCompletion)
        /// A pasted Google Maps link / shared text / "lat,lng".
        case link(String)
    }
    let id: String
    let title: String
    let subtitle: String
    let source: Source
}

/// Destination search. Google Places (New) when an API key is set, otherwise Apple Maps (MapKit).
/// Pasted Google Maps links work with either.
final class PlaceSearch: NSObject, ObservableObject, MKLocalSearchCompleterDelegate, CLLocationManagerDelegate {
    private enum Keys {
        static let provider = "search.provider"
        static let apiKey = "google.places.apiKey"
    }

    @Published var query = "" { didSet { queryChanged() } }
    @Published private(set) var suggestions: [Suggestion] = []
    @Published private(set) var error: String?
    @Published var provider: SearchProvider = .google {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: Keys.provider)
            queryChanged()
        }
    }
    @Published var apiKey = "" {
        didSet {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != apiKey { apiKey = trimmed }   // assigning inside didSet does not re-enter it
            Keychain.set(Keys.apiKey, trimmed)
            queryChanged()
        }
    }

    /// Google is used only when selected *and* a key is present.
    var effectiveProvider: SearchProvider { provider == .google && !apiKey.isEmpty ? .google : .apple }
    var googleClient: GooglePlacesClient? { apiKey.isEmpty ? nil : GooglePlacesClient(apiKey: apiKey) }
    var bundleId: String { Bundle.main.bundleIdentifier ?? "" }
    private(set) var here: CLLocationCoordinate2D?

    private var sessionToken = UUID().uuidString
    private var googleTask: Task<Void, Never>?
    private let completer = MKLocalSearchCompleter()
    private let location = CLLocationManager()

    override init() {
        super.init()
        _provider = Published(initialValue: SearchProvider(rawValue: UserDefaults.standard.string(forKey: Keys.provider) ?? "") ?? .google)
        _apiKey = Published(initialValue: Keychain.get(Keys.apiKey) ?? "")
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyKilometer
        location.requestWhenInUseAuthorization()
    }

    // MARK: - Query

    private func queryChanged() {
        googleTask?.cancel()
        error = nil
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { suggestions = []; return }

        if let u = GoogleMapsLink.extract(from: q).url, GoogleMapsLink.isGoogleMaps(u) {
            suggestions = [Suggestion(id: "link", title: "前往這個 Google 地圖連結", subtitle: u.host ?? "", source: .link(q))]
            return
        }
        if let c = GoogleMapsLink.coordinate(fromText: q) {
            suggestions = [Suggestion(id: "coord", title: "前往座標", subtitle: String(format: "%.6f, %.6f", c.latitude, c.longitude),
                                      source: .link(q))]
            return
        }

        switch effectiveProvider {
        case .apple:
            completer.queryFragment = q
        case .google:
            guard let client = googleClient else { return }
            let token = sessionToken
            let near = here
            googleTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)   // debounce: bill fewer requests
                guard !Task.isCancelled else { return }
                do {
                    let preds = try await client.autocomplete(q, sessionToken: token, near: near)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self?.suggestions = preds.map {
                            Suggestion(id: "g:" + $0.placeId, title: $0.mainText, subtitle: $0.secondaryText, source: .google($0))
                        }
                    }
                } catch {
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
                    let message = GooglePlacesClient.describe(error)
                    await MainActor.run { self?.error = message }
                }
            }
        }
    }

    /// Clipboard / share text → navigate. Returns a suggestion the UI can resolve like any other.
    func linkSuggestion(for text: String) -> Suggestion {
        Suggestion(id: "paste", title: "貼上的連結", subtitle: "", source: .link(text))
    }

    // MARK: - Resolve

    func resolve(_ s: Suggestion, log: @escaping (String) -> Void) async throws -> Destination {
        switch s.source {
        case .google(let p):
            guard let client = googleClient else { throw GoogleLinkResolver.Failure("尚未設定 Google API 金鑰") }
            let token = sessionToken
            sessionToken = UUID().uuidString    // the details call closes this autocomplete session
            do {
                let d = try await client.details(p.placeId, sessionToken: token)
                return Destination(name: p.mainText, address: d.formattedAddress ?? p.secondaryText,
                                   latitude: d.latitude, longitude: d.longitude)
            } catch {
                throw GoogleLinkResolver.Failure(GooglePlacesClient.describe(error))
            }
        case .apple(let c):
            guard let item = try await MKLocalSearch(request: MKLocalSearch.Request(completion: c)).start().mapItems.first else {
                throw GoogleLinkResolver.Failure("找不到這個地點")
            }
            return Destination(item)
        case .link(let text):
            return try await GoogleLinkResolver.resolve(text: text, places: googleClient, near: here, log: log)
        }
    }

    // MARK: - MKLocalSearchCompleterDelegate

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        guard effectiveProvider == .apple else { return }
        suggestions = completer.results.enumerated().map { i, c in
            Suggestion(id: "a:\(i):\(c.title)", title: c.title, subtitle: c.subtitle, source: .apple(c))
        }
        error = nil
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        guard effectiveProvider == .apple else { return }
        self.error = error.localizedDescription
    }

    // MARK: - CLLocationManagerDelegate (only to bias results toward where the car is)

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        here = loc.coordinate
        completer.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
