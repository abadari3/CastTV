import CastTVShared
import SwiftUI

@main
struct CastTViOSApp: App {
    @StateObject private var appState = iOSAppState()

    var body: some Scene {
        WindowGroup {
            HomeView(appState: appState)
        }
    }
}
