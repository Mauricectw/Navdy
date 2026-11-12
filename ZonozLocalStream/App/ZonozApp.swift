import SwiftUI

/// 把平台層、引擎、曲庫串起來的組裝點。
@MainActor
final class AppModel: ObservableObject {
    let platform: IOSPlatform
    let engine: CastEngine
    let library: MusicLibrary
    private var started = false

    init() {
        let platform = IOSPlatform()
        let engine = CastEngine(platform: platform)
        platform.engine = engine
        let library = MusicLibrary()
        library.onChange = { [weak engine] tracks in
            engine?.libraryChanged(tracks)
            engine?.libraryReady()
        }
        self.platform = platform
        self.engine = engine
        self.library = library
    }

    func start() {
        if started { return }
        started = true
        library.scan()
        engine.start()
    }

    func becameActive() {
        guard started else { return }
        platform.appBecameActive()
        engine.appBecameActive()
        library.scan()   // 使用者可能剛用「檔案」App 放了新歌進來
    }
}

@main
struct ZonozApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.engine)
                .environmentObject(model.library)
                .environmentObject(LogBus.shared)
        }
    }
}
