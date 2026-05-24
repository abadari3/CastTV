import CastTVShared
import SwiftUI

@main
struct CastTVtvOSApp: App {
    @StateObject private var appState = TVAppState()
    @StateObject private var remuxService = RemuxService()
    @State private var currentPlayMessage: PlayMessage?

    var body: some Scene {
        WindowGroup {
            Group {
                if let playMsg = currentPlayMessage, appState.isPlaying {
                    PlayerView(playMessage: playMsg, appState: appState, remuxService: remuxService)
                        .ignoresSafeArea()
                        .onExitCommand {
                            // Menu button pressed during playback — stop and return home
                            remuxService.stop()
                            appState.stopPlayback()
                            currentPlayMessage = nil
                        }
                } else {
                    TVHomeView(appState: appState)
                }
            }
            .onAppear {
                appState.onPlayRequest = { msg in
                    currentPlayMessage = msg
                }
            }
            .onChange(of: appState.isPlaying) { _, isPlaying in
                if !isPlaying {
                    remuxService.stop()
                    currentPlayMessage = nil
                }
            }
        }
    }
}
