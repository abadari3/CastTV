import SwiftUI
import CastTVShared

struct HomeView: View {
    @ObservedObject var appState: iOSAppState
    @State private var renamingDevice: PairedDevice?
    @State private var renameText: String = ""
    @State private var selectedDevice: PairedDevice?
    @State private var showOfflineAlert = false
    @State private var showManualPairing = false
    @State private var manualPairingCode = ""

    var body: some View {
        NavigationStack {
            List {
                if appState.pairedDevices.isEmpty {
                    ContentUnavailableView(
                        "No TVs",
                        systemImage: "tv",
                        description: Text("Tap + to scan a QR code from your Apple TV or Android TV")
                    )
                } else {
                    ForEach(appState.pairedDevices) { device in
                        DeviceRow(device: device, isOnline: appState.isOnline(device))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if appState.isOnline(device) {
                                    selectedDevice = device
                                } else {
                                    showOfflineAlert = true
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    appState.removeDevice(roomCode: device.roomCode)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button {
                                    renameText = device.name
                                    renamingDevice = device
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    appState.removeDevice(roomCode: device.roomCode)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            .refreshable {
                await appState.checkAllStatus()
            }
            .navigationTitle("CastTV")
            .toolbar {
                Menu {
                    Button {
                        appState.startScanning()
                    } label: {
                        Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    }
                    Button {
                        showManualPairing = true
                    } label: {
                        Label("Enter Code Manually", systemImage: "keyboard")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
            .task {
                await appState.checkAllStatus()
            }
            .onAppear {
                #if DEBUG
                ProbeTest.run()
                #endif
                #if targetEnvironment(simulator)
                if let pairString = ProcessInfo.processInfo.environment["CASTTV_AUTO_PAIR"],
                   !pairString.isEmpty,
                   appState.pairedDevices.isEmpty {
                    appState.handleScannedQR(pairString)
                }
                if let castURL = ProcessInfo.processInfo.environment["CASTTV_AUTO_CAST"],
                   !castURL.isEmpty,
                   !appState.pairedDevices.isEmpty {
                    // Delay to let WebSocket reconnect after pairing
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        appState.debugCastURL(castURL)
                    }
                }
                #endif
            }
            .sheet(isPresented: $appState.showScanner) {
                QRScannerView { code in
                    appState.handleScannedQR(code)
                }
            }
            .navigationDestination(item: $selectedDevice) { device in
                URLEntryView(device: device, appState: appState)
            }
            .alert("Rename TV", isPresented: .init(
                get: { renamingDevice != nil },
                set: { if !$0 { renamingDevice = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let device = renamingDevice, !renameText.isEmpty {
                        appState.renameDevice(roomCode: device.roomCode, newName: renameText)
                    }
                    renamingDevice = nil
                }
                Button("Cancel", role: .cancel) { renamingDevice = nil }
            }
            .alert("Manual Pairing", isPresented: $showManualPairing) {
                TextField("Paste casttv:... string", text: $manualPairingCode)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Pair") {
                    if !manualPairingCode.isEmpty {
                        appState.handleScannedQR(manualPairingCode)
                    }
                    manualPairingCode = ""
                }
                Button("Cancel", role: .cancel) { manualPairingCode = "" }
            } message: {
                Text("Paste the full casttv:ROOM:KEY string from the TV console log.")
            }
            .alert("TV Unavailable", isPresented: $showOfflineAlert) {
                Button("OK") {}
            } message: {
                Text("This TV is not currently available. Make sure the CastTV app is open on your TV.")
            }
            .overlay {
                if appState.isPairing {
                    ZStack {
                        Color.black.opacity(0.3).ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView()
                            Text("Pairing with TV...")
                        }
                        .padding(30)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .alert("Pairing Error", isPresented: .init(
                get: { appState.pairingError != nil },
                set: { if !$0 { appState.pairingError = nil } }
            )) {
                Button("OK") { appState.pairingError = nil }
            } message: {
                Text(appState.pairingError ?? "")
            }
        }
    }
}
