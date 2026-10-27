import XCTest
@testable import NavdyPlaces

private typealias L = GoogleMapsLink

final class GoogleMapsLinkTests: XCTestCase {
    private func parse(_ s: String) -> L.Target? { L.parse(url: URL(string: s)!) }

    func testPlaceURLPrefersPlaceCoordinatesOverCamera() {
        let u = "https://www.google.com/maps/place/%E5%8F%B0%E5%8C%97101/@25.0340000,121.5600000,17z/" +
            "data=!3m1!4b1!4m6!3m5!1s0x3442abb6da9c9e1f:0x1206bcf082fd10a6!8m2!3d25.0339639!4d121.5644722!16zL20vMDF6cjNn"
        XCTAssertEqual(parse(u), .coordinate(.init(25.0339639, 121.5644722), name: "台北101"))
    }

    func testPlaceNameWithPlusSigns() {
        let u = "https://www.google.com/maps/place/Taipei+101/data=!4m2!3m1!1s0x0:0x0!8m2!3d25.0339639!4d121.5644722"
        XCTAssertEqual(parse(u), .coordinate(.init(25.0339639, 121.5644722), name: "Taipei 101"))
    }

    func testPlaceNameOnlyBecomesQuery() {
        XCTAssertEqual(parse("https://www.google.com/maps/place/%E9%80%A2%E7%94%B2%E5%A4%9C%E5%B8%82/@24.18,120.64,15z"),
                       .query("逢甲夜市"))
    }

    func testDroppedPin() {
        XCTAssertEqual(parse("https://www.google.com/maps/place/24.1789,120.6467"),
                       .coordinate(.init(24.1789, 120.6467), name: nil))
        XCTAssertEqual(parse("https://www.google.com/maps/search/24.1789,+120.6467?entry=tts"),
                       .coordinate(.init(24.1789, 120.6467), name: nil))
    }

    func testQueryParameters() {
        XCTAssertEqual(parse("https://maps.google.com/?q=25.0339639,121.5644722"),
                       .coordinate(.init(25.0339639, 121.5644722), name: nil))
        XCTAssertEqual(parse("https://maps.google.com/maps?q=%E5%8F%B0%E4%B8%AD%E8%BB%8A%E7%AB%99"), .query("台中車站"))
        XCTAssertEqual(parse("https://www.google.com/maps/search/?api=1&query=Taichung+Station&query_place_id=ChIJabc123"),
                       .placeId("ChIJabc123", name: "Taichung Station"))
        XCTAssertEqual(parse("https://maps.google.com/?q=place_id:ChIJxyz"), .placeId("ChIJxyz", name: nil))
        XCTAssertEqual(parse("https://www.google.com/maps/dir/?api=1&destination=24.15,120.68"),
                       .coordinate(.init(24.15, 120.68), name: nil))
    }

    func testDirectionsUsesLastWaypoint() {
        let u = "https://www.google.com/maps/dir/%E5%8F%B0%E4%B8%AD/%E5%8F%B0%E5%8C%97101/@24.6,121.0,9z/" +
            "data=!3m1!4b1!4m13!4m12!1m5!1m1!1s0x0:0x1!2m2!1d120.6736!2d24.1477!1m5!1m1!1s0x0:0x2!2m2!1d121.5644722!2d25.0339639"
        XCTAssertEqual(parse(u), .coordinate(.init(25.0339639, 121.5644722), name: "台北101"))
    }

    func testCameraOnlyFallback() {
        XCTAssertEqual(parse("https://www.google.com/maps/@24.1477,120.6736,15z"),
                       .coordinate(.init(24.1477, 120.6736), name: nil))
    }

    func testConsentWrapper() {
        let inner = "https://www.google.com/maps/place/X/data=!3d24.1!4d120.6"
        let u = "https://consent.google.com/m?continue=" + inner.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! + "&gl=TW"
        XCTAssertEqual(parse(u), .coordinate(.init(24.1, 120.6), name: "X"))
    }

    func testGeoURI() {
        XCTAssertEqual(L.parse(url: URL(string: "geo:24.1477,120.6736")!), .coordinate(.init(24.1477, 120.6736), name: nil))
        XCTAssertEqual(L.parse(url: URL(string: "geo:0,0?q=24.1477,120.6736(Station)")!),
                       .coordinate(.init(24.1477, 120.6736), name: "Station"))
    }

    func testInvalidCoordinatesRejected() {
        XCTAssertNil(L.coordinate(fromText: "95.0,120.0"))
        XCTAssertNil(L.coordinate(fromText: "0,0"))
        XCTAssertNil(L.coordinate(fromText: "hello"))
    }

    func testShortLinkDetection() {
        XCTAssertTrue(L.isShortLink(URL(string: "https://maps.app.goo.gl/AbCdEf123?g_st=ic")!))
        XCTAssertTrue(L.isShortLink(URL(string: "https://goo.gl/maps/AbCd")!))
        XCTAssertFalse(L.isShortLink(URL(string: "https://goo.gl/other")!))
        XCTAssertTrue(L.isGoogleMaps(URL(string: "https://www.google.com.tw/maps/place/X")!))
        XCTAssertFalse(L.isGoogleMaps(URL(string: "https://www.google.com/search?q=x")!))
    }

    func testSharedTextFromGoogleMapsApp() {
        let text = "台北101\n110台北市信義區信義路五段7號\nhttps://maps.app.goo.gl/AbCdEf123?g_st=ic"
        let s = L.extract(from: text)
        XCTAssertEqual(s.url?.host, "maps.app.goo.gl")
        XCTAssertEqual(s.textLines, ["台北101", "110台北市信義區信義路五段7號"])
        // Without expanding the short link we can still geocode the text.
        XCTAssertEqual(L.parse(shared: s), .query("台北101 110台北市信義區信義路五段7號"))
    }

    func testSharedTextNameFillsMissingName() {
        let s = L.extract(from: "My pin https://maps.google.com/?q=24.1,120.6")
        XCTAssertEqual(s.textLines, ["My pin"])
        XCTAssertEqual(L.parse(shared: s), .coordinate(.init(24.1, 120.6), name: "My pin"))
    }

    func testEmbeddedRedirectInBody() {
        let body = #"<script>window.location="https:\/\/www.google.com\/maps\/place\/X\/data=!3d24.1!4d120.6?entry=tts";</script>"#
        let u = L.embeddedMapsURL(inBody: body)
        XCTAssertEqual(u.flatMap(L.parse(url:)), .coordinate(.init(24.1, 120.6), name: "X"))
    }
}

final class GooglePlacesTests: XCTestCase {
    func testAutocompleteBody() throws {
        let d = try GooglePlaces.autocompleteBody(input: "台中車站", sessionToken: "tok",
                                                   bias: (latitude: 24.1, longitude: 120.6, radiusMeters: 90_000))
        let o = try JSONSerialization.jsonObject(with: d) as! [String: Any]
        XCTAssertEqual(o["input"] as? String, "台中車站")
        XCTAssertEqual(o["sessionToken"] as? String, "tok")
        XCTAssertEqual(o["languageCode"] as? String, "zh-TW")
        XCTAssertEqual(o["regionCode"] as? String, "tw")
        let circle = (o["locationBias"] as? [String: Any])?["circle"] as? [String: Any]
        let radius: Double? = {
            switch circle?["radius"] {
            case let d as Double: return d
            case let i as Int: return Double(i)
            case let n as NSNumber: return n.doubleValue
            default: return nil
            }
        }()
        XCTAssertEqual(radius, 50_000)   // clamped to API max
    }

    func testDetailsURL() {
        let u = GooglePlaces.detailsURL(placeId: "places/ChIJ_abc-123", sessionToken: "tok")
        XCTAssertEqual(u.absoluteString, "https://places.googleapis.com/v1/places/ChIJ_abc-123?languageCode=zh-TW&sessionToken=tok")
    }

    func testHeaders() {
        let h = GooglePlaces.headers(apiKey: "K", bundleId: "tw.app", fieldMask: GooglePlaces.detailsFieldMask)
        XCTAssertEqual(h["X-Goog-Api-Key"], "K")
        XCTAssertEqual(h["X-Ios-Bundle-Identifier"], "tw.app")
        XCTAssertEqual(h["X-Goog-FieldMask"], "location,formattedAddress")
    }

    func testParseAutocomplete() throws {
        let json = """
        {"suggestions":[
          {"placePrediction":{"place":"places/ChIJ1","placeId":"ChIJ1",
            "text":{"text":"台中車站, 台中市中區"},
            "structuredFormat":{"mainText":{"text":"台中車站"},"secondaryText":{"text":"台中市中區台灣大道一段1號"}}}},
          {"queryPrediction":{"text":{"text":"台中車站 美食"}}},
          {"placePrediction":{"place":"places/ChIJ2","text":{"text":"台中公園"}}}
        ]}
        """
        let p = try GooglePlaces.parseAutocomplete(Data(json.utf8))
        XCTAssertEqual(p, [
            .init(placeId: "ChIJ1", mainText: "台中車站", secondaryText: "台中市中區台灣大道一段1號"),
            .init(placeId: "ChIJ2", mainText: "台中公園", secondaryText: ""),
        ])
        XCTAssertEqual(try GooglePlaces.parseAutocomplete(Data("{}".utf8)), [])
    }

    func testParseDetails() throws {
        let json = #"{"formattedAddress":"400台灣台中市中區台灣大道一段1號","location":{"latitude":24.1372,"longitude":120.6869}}"#
        XCTAssertEqual(try GooglePlaces.parseDetails(Data(json.utf8)),
                       .init(latitude: 24.1372, longitude: 120.6869, formattedAddress: "400台灣台中市中區台灣大道一段1號"))
    }

    func testAPIErrorSurfaced() {
        let json = #"{"error":{"code":403,"message":"Requests from this iOS client application <empty> are blocked.","status":"PERMISSION_DENIED"}}"#
        XCTAssertThrowsError(try GooglePlaces.parseAutocomplete(Data(json.utf8))) { e in
            XCTAssertEqual((e as? GooglePlaces.APIError)?.code, 403)
            XCTAssertEqual((e as? GooglePlaces.APIError)?.status, "PERMISSION_DENIED")
        }
    }
}
