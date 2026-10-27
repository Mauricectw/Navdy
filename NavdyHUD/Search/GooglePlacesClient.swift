import CoreLocation
import Foundation
import NavdyPlaces

/// Thin URLSession wrapper around Google Places API (New). Request/response shapes live in
/// NavdyPlaces (unit-tested); this file only does the HTTP.
struct GooglePlacesClient {
    let apiKey: String

    private static let session = URLSession(configuration: .ephemeral)
    private var bundleId: String? { Bundle.main.bundleIdentifier }

    func autocomplete(_ input: String, sessionToken: String, near: CLLocationCoordinate2D?) async throws -> [GooglePlaces.Prediction] {
        var req = URLRequest(url: GooglePlaces.autocompleteURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        let bias = near.map { (latitude: $0.latitude, longitude: $0.longitude, radiusMeters: 50_000.0) }
        req.httpBody = try GooglePlaces.autocompleteBody(input: input, sessionToken: sessionToken, bias: bias)
        for (k, v) in GooglePlaces.headers(apiKey: apiKey, bundleId: bundleId) { req.setValue(v, forHTTPHeaderField: k) }
        let (data, _) = try await Self.session.data(for: req)
        return try GooglePlaces.parseAutocomplete(data)
    }

    func details(_ placeId: String, sessionToken: String?) async throws -> GooglePlaces.Details {
        var req = URLRequest(url: GooglePlaces.detailsURL(placeId: placeId, sessionToken: sessionToken))
        req.timeoutInterval = 10
        let headers = GooglePlaces.headers(apiKey: apiKey, bundleId: bundleId, fieldMask: GooglePlaces.detailsFieldMask)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, _) = try await Self.session.data(for: req)
        return try GooglePlaces.parseDetails(data)
    }

    /// Search text → best match (one autocomplete session ending in one details call).
    func firstMatch(_ text: String, near: CLLocationCoordinate2D?) async throws -> (GooglePlaces.Prediction, GooglePlaces.Details)? {
        let token = UUID().uuidString
        guard let p = try await autocomplete(text, sessionToken: token, near: near).first else { return nil }
        return (p, try await details(p.placeId, sessionToken: token))
    }

    /// Turns common setup mistakes into instructions.
    static func describe(_ error: Error) -> String {
        guard let e = error as? GooglePlaces.APIError else {
            if let u = error as? URLError { return "網路錯誤：\(u.localizedDescription)" }
            return error.localizedDescription
        }
        let m = e.message.lowercased()
        if m.contains("api key not valid") || m.contains("api_key_invalid") {
            return "API 金鑰無效，請確認複製完整。"
        }
        if m.contains("ios client application") || m.contains("bundle") {
            return "金鑰的「iOS 應用程式」限制不符：請把 Bundle ID 設為 \(Bundle.main.bundleIdentifier ?? "?")（設定頁可複製）。"
        }
        if m.contains("has not been used") || m.contains("is disabled") || m.contains("service_disabled") {
            return "這個 Google Cloud 專案還沒啟用「Places API (New)」。"
        }
        if m.contains("billing") {
            return "Google Cloud 專案需要先綁定計費帳戶（有每月免費額度）。"
        }
        if e.code == 429 || e.status == "RESOURCE_EXHAUSTED" {
            return "已達 Google 用量上限，請稍後再試或檢查配額設定。"
        }
        return "Google 回傳錯誤：\(e.description)"
    }
}
