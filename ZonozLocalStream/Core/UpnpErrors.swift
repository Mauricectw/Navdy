import Foundation

/// UPnP / Sonos 錯誤碼。數字碼只留在日誌，給使用者看的文案在 UI 層（L10n）。
enum UpnpErrors {

    enum Kind {
        case reach      // 701/702/716：音箱拿不到媒體串流
        case format     // 714：格式不被接受
        case badRequest // 402：參數/中繼資料有問題
        case offline    // 800 / 無錯誤碼：根本連不上
        case satellite  // 1023：Sonos 私有，從設備
        case unknown
    }

    static let satelliteCode = 1023

    static func kind(_ code: Int?) -> Kind {
        guard let code = code else { return .offline }
        switch code {
        case 701, 702, 716: return .reach
        case 714: return .format
        case 402: return .badRequest
        case 800: return .offline
        case 1023: return .satellite
        default: return .unknown
        }
    }

    static func describe(_ code: Int?) -> String {
        guard let code = code else { return "no UPnP error code" }
        switch code {
        case 401: return "Invalid Action"
        case 402: return "Invalid Args"
        case 501: return "Action Failed"
        case 701: return "Transition not available"
        case 702: return "No contents"
        case 704: return "Invalid connection reference"
        case 705: return "Transport is locked"
        case 710: return "Seek mode not supported"
        case 711: return "Illegal seek target"
        case 712: return "Play speed not supported"
        case 714: return "Illegal MIME-Type"
        case 715: return "Content busy"
        case 716: return "Resource not found"
        case 718: return "Invalid InstanceID"
        case 800: return "Unable to connect"
        case 1023: return "Satellite unit (Sonos private)"
        default: return "UPnP \(code)"
        }
    }
}
