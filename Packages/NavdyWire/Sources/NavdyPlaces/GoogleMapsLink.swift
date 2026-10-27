import Foundation

/// Turns whatever the Google Maps app shares ("名稱\n地址\nhttps://maps.app.goo.gl/…") or any
/// google.com/maps URL into something we can navigate to. Pure parsing, no network: short links
/// are expanded by the app first (GoogleLinkResolver), then fed back through `parse(url:)`.
public enum GoogleMapsLink {
    public struct LatLng: Equatable {
        public var latitude: Double
        public var longitude: Double
        public init(_ latitude: Double, _ longitude: Double) { self.latitude = latitude; self.longitude = longitude }
        var isValid: Bool { (-90...90).contains(latitude) && (-180...180).contains(longitude) && !(latitude == 0 && longitude == 0) }
    }

    public enum Target: Equatable {
        /// Exact coordinates of the place (or of a dropped pin).
        case coordinate(LatLng, name: String?)
        /// A Google place ID; needs a Place Details call (API key) to get coordinates.
        case placeId(String, name: String?)
        /// Only text (name and/or address); must be geocoded.
        case query(String)
    }

    /// What the share sheet / clipboard contained.
    public struct Shared: Equatable {
        public var url: URL?
        /// Non-URL lines, usually place name then address.
        public var textLines: [String]
    }

    // MARK: - Shared text

    public static func extract(from text: String) -> Shared {
        var url: URL?
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if url == nil, let r = line.range(of: #"(https?://|geo:)\S+"#, options: .regularExpression) {
                url = URL(string: String(line[r]))
                let rest = line.replacingCharacters(in: r, with: "").trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { lines.append(rest) }
            } else {
                lines.append(line)
            }
        }
        return Shared(url: url, textLines: lines)
    }

    /// Short links that must be expanded over the network before parsing.
    public static func isShortLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "maps.app.goo.gl" || host == "g.co" { return true }
        if host == "goo.gl", url.path.hasPrefix("/maps") { return true }
        return false
    }

    public static func isGoogleMaps(_ url: URL) -> Bool {
        if url.scheme == "geo" { return true }
        guard let host = url.host?.lowercased() else { return false }
        if isShortLink(url) { return true }
        if host.hasPrefix("maps.google.") { return true }
        if host.contains("google."), url.path.hasPrefix("/maps") { return true }
        if host.hasPrefix("consent.google.") { return true }
        return false
    }

    // MARK: - URL parsing

    public static func parse(url: URL) -> Target? {
        if url.scheme == "geo" { return parseGeo(url) }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = Dictionary(comps.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { a, _ in a })

        // EU-style consent interstitial wraps the real URL.
        if url.host?.lowercased().hasPrefix("consent.google.") == true,
           let cont = query["continue"], let inner = URL(string: cont) {
            return parse(url: inner)
        }

        let path = url.path   // percent-decoded by Foundation
        let name = placeName(fromPath: path)

        // 1) "!3d<lat>!4d<lng>" in /data= is the place itself (most precise).
        let full = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        if let p = lastMatch(#"!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)"#, in: full),
           let c = latLng(p.0, p.1) {
            return .coordinate(c, name: name)
        }
        // 2) Directions: destination is the last "!1d<lng>!2d<lat>" pair (note: lng first).
        if path.hasPrefix("/maps/dir"),
           let p = lastMatch(#"!1d(-?\d+(?:\.\d+)?)!2d(-?\d+(?:\.\d+)?)"#, in: full),
           let c = latLng(p.1, p.0) {
            return .coordinate(c, name: lastDirSegment(path))
        }
        // 3) Explicit query parameters.
        for key in ["query_place_id", "destination_place_id"] {
            if let id = query[key], !id.isEmpty { return .placeId(id, name: query["query"].flatMap(cleanText) ?? name) }
        }
        for key in ["q", "query", "destination", "daddr", "ll", "center"] {
            guard let v = query[key].flatMap(cleanText) else { continue }
            if v.hasPrefix("place_id:") { return .placeId(String(v.dropFirst("place_id:".count)), name: name) }
            if let c = coordinate(fromText: v) { return .coordinate(c, name: name) }
            if key != "ll", key != "center" { return .query(v) }
        }
        // 4) "/maps/place/<lat>,<lng>" or "/maps/search/<lat>,<lng>"
        if let seg = pathSegment(after: ["place", "search"], in: path), let c = coordinate(fromText: seg) {
            return .coordinate(c, name: nil)
        }
        // 5) Name only (e.g. /maps/place/台北101/@viewport). The "@lat,lng" is just the camera, so
        //    prefer geocoding the name; fall back to the camera if there is no name.
        if let name { return .query(name) }
        if let p = lastMatch(#"/@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)"#, in: full), let c = latLng(p.0, p.1) {
            return .coordinate(c, name: nil)
        }
        if let seg = pathSegment(after: ["search"], in: path), let q = cleanText(seg) { return .query(q) }
        return nil
    }

    /// Parse shared text: URL first, then fall back to the text lines.
    public static func parse(shared: Shared) -> Target? {
        let fallbackName = shared.textLines.first
        if let url = shared.url, !isShortLink(url), let t = parse(url: url) {
            switch t {
            case .coordinate(let c, nil): return .coordinate(c, name: fallbackName)
            case .placeId(let id, nil): return .placeId(id, name: fallbackName)
            default: return t
            }
        }
        if let first = shared.textLines.first, let c = coordinate(fromText: first) { return .coordinate(c, name: nil) }
        let text = shared.textLines.prefix(2).joined(separator: " ")
        return text.isEmpty ? nil : .query(text)
    }

    /// Scans an HTML/JS body for a full google.com/maps URL (some short links answer 200 + JS redirect).
    public static func embeddedMapsURL(inBody body: String) -> URL? {
        let pattern = #"https?:(?:\\?/){2}(?:www\.)?google\.[a-z.]+(?:\\?/)maps[^"'<>\s\\]*(?:\\/[^"'<>\s\\]*)*"#
        guard let r = body.range(of: pattern, options: .regularExpression) else { return nil }
        let s = String(body[r]).replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "&amp;", with: "&")
        return URL(string: s)
    }

    // MARK: - Helpers

    public static func coordinate(fromText text: String) -> LatLng? {
        let t = text.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "+", with: "")
        guard let m = lastMatch(#"^(-?\d{1,2}(?:\.\d+)?),(-?\d{1,3}(?:\.\d+)?)$"#, in: t) else { return nil }
        return latLng(m.0, m.1)
    }

    private static func parseGeo(_ url: URL) -> Target? {
        // geo:lat,lng?q=lat,lng(Label)  or  geo:0,0?q=address
        let s = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        let body = s.dropFirst("geo:".count)
        let parts = body.split(separator: "?", maxSplits: 1)
        var q: String?
        if parts.count == 2 {
            q = URLComponents(string: "x:?" + parts[1])?.queryItems?.first { $0.name == "q" }?.value
        }
        var label: String?
        if let qq = q, let open = qq.firstIndex(of: "("), qq.hasSuffix(")") {
            label = String(qq[qq.index(after: open)..<qq.index(before: qq.endIndex)])
            q = String(qq[..<open])
        }
        if let q, let c = coordinate(fromText: q) { return .coordinate(c, name: label) }
        if let c = coordinate(fromText: String(parts.first?.split(separator: ";").first ?? "")) {
            return .coordinate(c, name: label)
        }
        if let q = q.flatMap(cleanText) { return .query(q) }
        return nil
    }

    private static func placeName(fromPath path: String) -> String? {
        guard let seg = pathSegment(after: ["place"], in: path), coordinate(fromText: seg) == nil else { return nil }
        return cleanText(seg)
    }

    private static func lastDirSegment(_ path: String) -> String? {
        let segs = path.split(separator: "/").map(String.init)
        guard let i = segs.firstIndex(of: "dir") else { return nil }
        return segs[(i + 1)...].last { !$0.hasPrefix("@") && !$0.hasPrefix("data=") && !$0.isEmpty }.flatMap(cleanText)
    }

    private static func pathSegment(after keys: [String], in path: String) -> String? {
        let segs = path.split(separator: "/").map(String.init)
        guard let i = segs.firstIndex(where: { keys.contains($0) }), i + 1 < segs.count else { return nil }
        let seg = segs[i + 1]
        return seg.hasPrefix("@") || seg.hasPrefix("data=") ? nil : seg
    }

    private static func cleanText(_ s: String) -> String? {
        let t = (s.removingPercentEncoding ?? s).replacingOccurrences(of: "+", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func latLng(_ a: String, _ b: String) -> LatLng? {
        guard let lat = Double(a), let lng = Double(b) else { return nil }
        let c = LatLng(lat, lng)
        return c.isValid ? c : nil
    }

    private static func lastMatch(_ pattern: String, in s: String) -> (String, String)? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.matches(in: s, range: NSRange(location: 0, length: ns.length)).last, m.numberOfRanges >= 3 else {
            return nil
        }
        return (ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)))
    }
}
