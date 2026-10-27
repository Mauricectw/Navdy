import Foundation

/// Request builders and response models for Google Places API (New), kept free of networking so
/// they can be unit-tested on Linux. The app performs the requests with URLSession.
///
/// Billing (Google Maps Platform price list):
///   - Autocomplete requests that end in a Place Details call with the same sessionToken are
///     billed as one "session" and the autocomplete part is free;
///   - Place Details with only `location,formattedAddress` is the "Essentials" SKU
///     (10,000 free per month). `displayName` would bump it to "Pro", so the name shown on the HUD
///     comes from the autocomplete prediction instead.
public enum GooglePlaces {
    public static let autocompleteURL = URL(string: "https://places.googleapis.com/v1/places:autocomplete")!
    public static let detailsFieldMask = "location,formattedAddress"

    public struct Prediction: Equatable, Identifiable {
        public var placeId: String
        public var mainText: String
        public var secondaryText: String
        public var id: String { placeId }
    }

    public struct Details: Equatable {
        public var latitude: Double
        public var longitude: Double
        public var formattedAddress: String?
    }

    public struct APIError: Error, CustomStringConvertible, Equatable {
        public var code: Int?
        public var status: String?
        public var message: String
        public var description: String {
            [status, message].compactMap { $0 }.joined(separator: ": ")
        }
    }

    // MARK: - Requests

    public static func autocompleteBody(input: String, sessionToken: String, languageCode: String = "zh-TW",
                                        regionCode: String? = "tw",
                                        bias: (latitude: Double, longitude: Double, radiusMeters: Double)? = nil) throws -> Data {
        var body: [String: Any] = ["input": input, "sessionToken": sessionToken, "languageCode": languageCode]
        if let regionCode { body["regionCode"] = regionCode }
        if let b = bias {
            let center: [String: Any] = ["latitude": b.latitude, "longitude": b.longitude]
            let circle: [String: Any] = ["center": center, "radius": min(max(b.radiusMeters, 1), 50_000)]
            body["locationBias"] = ["circle": circle] as [String: Any]
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    public static func detailsURL(placeId: String, sessionToken: String?, languageCode: String = "zh-TW") -> URL {
        let id = placeId.hasPrefix("places/") ? String(placeId.dropFirst("places/".count)) : placeId
        var c = URLComponents(string: "https://places.googleapis.com/v1/places/")!
        c.percentEncodedPath += id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        var items = [URLQueryItem(name: "languageCode", value: languageCode)]
        if let sessionToken { items.append(URLQueryItem(name: "sessionToken", value: sessionToken)) }
        c.queryItems = items
        return c.url!
    }

    /// Headers for every call. `bundleId` must match the key's "iOS apps" restriction, if any.
    public static func headers(apiKey: String, bundleId: String?, fieldMask: String? = nil) -> [String: String] {
        var h = ["X-Goog-Api-Key": apiKey, "Content-Type": "application/json"]
        if let bundleId { h["X-Ios-Bundle-Identifier"] = bundleId }
        if let fieldMask { h["X-Goog-FieldMask"] = fieldMask }
        return h
    }

    // MARK: - Responses

    public static func parseAutocomplete(_ data: Data) throws -> [Prediction] {
        let root = try object(data)
        if let e = apiError(root) { throw e }
        let suggestions = root["suggestions"] as? [[String: Any]] ?? []
        return suggestions.compactMap { s in
            guard let p = s["placePrediction"] as? [String: Any] else { return nil }   // skip queryPrediction
            guard let id = (p["placeId"] as? String) ?? (p["place"] as? String).map({ $0.replacingOccurrences(of: "places/", with: "") })
            else { return nil }
            let fmt = p["structuredFormat"] as? [String: Any]
            let main = ((fmt?["mainText"] as? [String: Any])?["text"] as? String)
                ?? ((p["text"] as? [String: Any])?["text"] as? String) ?? ""
            let secondary = ((fmt?["secondaryText"] as? [String: Any])?["text"] as? String) ?? ""
            return Prediction(placeId: id, mainText: main, secondaryText: secondary)
        }
    }

    public static func parseDetails(_ data: Data) throws -> Details {
        let root = try object(data)
        if let e = apiError(root) { throw e }
        guard let loc = root["location"] as? [String: Any],
              let lat = number(loc["latitude"]),
              let lng = number(loc["longitude"])
        else { throw APIError(code: nil, status: nil, message: "回應中沒有座標") }
        return Details(latitude: lat, longitude: lng, formattedAddress: root["formattedAddress"] as? String)
    }

    /// JSONSerialization yields Double/Int on Darwin and NSNumber on Linux; accept all.
    private static func number(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        default: return nil
        }
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(code: nil, status: nil, message: "無法解析的回應")
        }
        return o
    }

    private static func apiError(_ root: [String: Any]) -> APIError? {
        guard let e = root["error"] as? [String: Any] else { return nil }
        return APIError(code: number(e["code"]).map { Int($0) }, status: e["status"] as? String,
                        message: e["message"] as? String ?? "未知錯誤")
    }
}
