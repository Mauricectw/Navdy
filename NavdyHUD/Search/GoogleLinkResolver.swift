import CoreLocation
import Foundation
import MapKit
import NavdyPlaces

/// Resolves what the user shared/pasted from the Google Maps app to a destination.
/// Works without an API key: coordinates are read from the expanded link; only links that carry
/// nothing but a name are geocoded (with Google if a key is set, otherwise Apple).
enum GoogleLinkResolver {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    static func resolve(text: String, places: GooglePlacesClient?, near: CLLocationCoordinate2D?,
                        log: (String) -> Void = { _ in }) async throws -> Destination {
        var shared = GoogleMapsLink.extract(from: text)
        if let u = shared.url, GoogleMapsLink.isShortLink(u) {
            let expanded = try await expand(u)
            log("短網址展開：\(expanded?.absoluteString.prefix(160) ?? "失敗")")
            shared.url = expanded
        }
        guard let target = GoogleMapsLink.parse(shared: shared) else {
            throw Failure("看不懂這個連結，請改用搜尋。")
        }
        let textName = shared.textLines.first
        let textAddress = shared.textLines.count > 1 ? shared.textLines[1] : nil

        switch target {
        case .coordinate(let c, let name):
            return Destination(name: name ?? textName ?? "地圖標記", address: textAddress,
                               latitude: c.latitude, longitude: c.longitude)
        case .placeId(let id, let name):
            if let places {
                let d = try await places.details(id, sessionToken: nil)
                return Destination(name: name ?? textName ?? d.formattedAddress ?? "目的地",
                                   address: d.formattedAddress, latitude: d.latitude, longitude: d.longitude)
            }
            guard let q = name ?? textName else { throw Failure("此連結需要 Google API 金鑰才能解析。") }
            return try await geocode(q, displayName: q, places: nil, near: near)
        case .query(let q):
            return try await geocode(q, displayName: textName, places: places, near: near)
        }
    }

    static func geocode(_ query: String, displayName: String?, places: GooglePlacesClient?,
                        near: CLLocationCoordinate2D?) async throws -> Destination {
        if let places, let match = try await places.firstMatch(query, near: near) {
            let (p, d) = match
            return Destination(name: displayName ?? p.mainText, address: d.formattedAddress,
                               latitude: d.latitude, longitude: d.longitude)
        }
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        if let near { req.region = MKCoordinateRegion(center: near, latitudinalMeters: 100_000, longitudinalMeters: 100_000) }
        guard let item = try await MKLocalSearch(request: req).start().mapItems.first else {
            throw Failure("找不到「\(query)」")
        }
        var dest = Destination(item)
        if let displayName { dest.name = displayName }
        return dest
    }

    /// Follows maps.app.goo.gl / goo.gl/maps redirects. Some answers are an HTML/JS redirect page,
    /// so the body is scanned too.
    private static func expand(_ url: URL) async throws -> URL? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        // A desktop UA gets plain HTTP redirects instead of an "open in app" page.
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("zh-TW,zh;q=0.9,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let final = response.url, !GoogleMapsLink.isShortLink(final), GoogleMapsLink.parse(url: final) != nil {
            return final
        }
        let body = String(decoding: data.prefix(2_000_000), as: UTF8.self)
        return GoogleMapsLink.embeddedMapsURL(inBody: body) ?? response.url
    }
}
