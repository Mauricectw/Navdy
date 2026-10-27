import SwiftUI

@main
struct NavdyHUDApp: App {
    @StateObject private var hud = HUDController()
    @StateObject private var search = PlaceSearch()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(hud)
                .environmentObject(search)
        }
    }
}
