import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var search: PlaceSearch
    @Environment(\.dismiss) private var dismiss
    @State private var keyDraft = ""
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("搜尋來源", selection: $search.provider) {
                        ForEach(SearchProvider.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("HUD 上顯示的地圖與路線由 HUD 內建的 HERE 離線地圖計算，這裡只決定手機用哪家搜尋目的地。" +
                         "從 Google 地圖 App 分享的連結，兩種來源都能用。")
                }

                Section {
                    SecureField("貼上 API 金鑰（AIza…）", text: $keyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("儲存金鑰") {
                        search.apiKey = keyDraft
                        testResult = nil
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces) == search.apiKey)
                    if !search.apiKey.isEmpty {
                        Button(testing ? "測試中…" : "測試金鑰") { Task { await test() } }
                            .disabled(testing)
                        Button("刪除金鑰", role: .destructive) {
                            search.apiKey = ""
                            keyDraft = ""
                            testResult = nil
                        }
                    }
                    if let testResult { Text(testResult).font(.footnote) }
                } header: {
                    Text("Google Places API 金鑰")
                } footer: {
                    Text(search.apiKey.isEmpty
                         ? "未設定金鑰時，搜尋會使用 Apple 地圖。申請步驟見 README。"
                         : "金鑰存在這支手機的鑰匙圈中，不會上傳到其他地方。")
                }

                Section {
                    LabeledContent("Bundle ID", value: search.bundleId)
                    Button("複製 Bundle ID") { UIPasteboard.general.string = search.bundleId }
                } header: {
                    Text("金鑰限制用")
                } footer: {
                    Text("在 Google Cloud 把金鑰限制為「iOS 應用程式」時，要填這個 Bundle ID。" +
                         "用 Sideloadly 安裝時 Bundle ID 可能被改過，請以這裡顯示的為準。")
                }
            }
            .navigationTitle("設定")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onAppear { keyDraft = search.apiKey }
        }
    }

    private func test() async {
        guard let client = search.googleClient else { return }
        testing = true
        defer { testing = false }
        do {
            let r = try await client.autocomplete("台北車站", sessionToken: UUID().uuidString, near: search.here)
            testResult = r.isEmpty ? "金鑰可用，但沒有搜尋結果。" : "✅ 金鑰可用：\(r[0].mainText)"
        } catch {
            testResult = "❌ " + GooglePlacesClient.describe(error)
        }
    }
}
