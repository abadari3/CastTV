# Apple (iOS + tvOS)

Two native Swift/SwiftUI apps sharing a common library, built with XcodeGen.

## Build System

- **XcodeGen**: `project.yml` generates the Xcode project — no raw `.pbxproj` edits
- **Info.plist**: Auto-generated (`GENERATE_INFOPLIST_FILE: YES`), configured via `INFOPLIST_KEY_*` in `project.yml`
- **Deployment targets**: iOS 18.0, tvOS 18.0
- **Swift packages**: `CastTVShared` (shared logic), `FFmpegKit` (media processing)

## Package Structure

### CastTVShared (shared Swift package)

Used by both iOS and tvOS targets.

```
Sources/CastTVShared/
  Protocol/
    CastMessage.swift     # Message routing enum (peek at type/action, dispatch)
    Messages.swift         # PlayMessage, CapabilitiesMessage, ErrorMessage, LogMessage, etc.
    TrackInfo.swift        # ProbeResult, VideoTrackInfo, AudioTrackInfo, SubtitleTrackInfo
  Networking/
    WebSocketClient.swift  # Encrypted WebSocket (URLSession, auto-reconnect)
    BonjourAdvertiser.swift # NWListener: TV advertises _casttv._tcp service
    BonjourBrowser.swift    # NWBrowser: iPhone discovers nearby TVs
    RoomStatus.swift        # HTTP status check (no WebSocket needed)
    Constants.swift         # Server URL, room code charset/length
  Crypto/
    Encryption.swift        # AES-256-GCM via CryptoKit
    QRCodeData.swift        # Encode/decode casttv:<room>:<key> + QR image generation
    RoomCodeGenerator.swift # Random 6-char code with server availability check
  Storage/
    PairingStorage.swift    # UserDefaults (device metadata) + Keychain (encryption keys)
    KeychainHelper.swift    # SymmetricKey ↔ Keychain per room code
    URLHistory.swift        # Playback URL history
    ResumeStorage.swift     # Resume position persistence
  Media/
    CompatibilityEngine.swift # Determines: native / needs processing / unsupported per codec
    AVProber.swift            # AVFoundation-based media probing (MP4/MOV/HLS)
    Formatting.swift          # Duration/bitrate formatting, compatibility color coding
  Logging/
    Logger.swift              # CastTVLogger: JSON file logging, in-memory buffer, WebSocket streaming
```

### FFmpegKit (media processing package)

```
Sources/FFmpegKit/
  FFRemuxer.swift          # HLS remuxing: any container → M3U8 + MPEG-TS segments
  FFProber.swift           # FFmpeg-based media probing (MKV, WebM, AVI, etc.)
  SubtitleConverter.swift  # SRT/ASS → WebVTT conversion
Frameworks/
  FFmpeg.xcframework       # Pre-built FFmpeg binary (built via scripts/build-ffmpeg.sh)
```

## iOS App

The iPhone is the **remote control and media browser**.

```
iOS/
  CastTViOSApp.swift       # App entry point
  State/
    iOSAppState.swift       # @MainActor ObservableObject: devices, pairing, Bonjour browsing, status checks
  Views/
    HomeView.swift           # Device list + nearby TV discovery
    QRScannerView.swift      # Camera-based QR scanning
    URLEntryView.swift       # URL input, clipboard detection, subtitle URL, probe trigger
    ProbeResultsView.swift   # Track picker with color-coded compatibility badges
    DeviceRow.swift          # Paired device list row (online indicator, capabilities)
    LogViewerView.swift      # Remote TV log viewer
  Media/
    MediaProber.swift        # Dual-path: AVFoundation for native containers, FFmpeg fallback
```

**iOS flow**: Enter URL → Probe → Pick tracks → Check compatibility → Send PlayMessage with ProcessingRequirements

## tvOS App

The TV is the **playback engine**.

```
tvOS/
  CastTVtvOSApp.swift       # App entry point
  State/
    TVAppState.swift         # @MainActor ObservableObject: pairing, WebSocket, playback, Bonjour advertising
  Views/
    TVHomeView.swift         # QR code display + connection status
    PlayerView.swift         # AVPlayer wrapper
    DirectURLView.swift      # Debug: direct URL input
  Playback/
    RemuxService.swift       # Orchestrates FFmpeg remux pipeline (states: idle→starting→running→finished)
    LocalServer.swift        # HTTP server (Network.framework) serving HLS segments on localhost
    SegmentStorage.swift     # Temp file management for M3U8 + TS + VTT segments
  Media/
    TVMediaProber.swift      # Media probing on TV side
    CapabilityDetector.swift # Detects display (4K, HDR modes), audio (channels, Atmos) via system APIs
```

**tvOS playback pipeline**: Receive PlayMessage → FFmpeg remux to HLS (if needed) → LocalServer serves segments → AVPlayer consumes from localhost

## Conventions

- **State management**: `@MainActor` `ObservableObject` with `@Published` properties
- **Async patterns**: `AsyncStream` for WebSocket messages/states and Bonjour discoveries
- **Encryption keys**: Stored in Keychain per room code, device metadata in UserDefaults
- **Logging**: `CastTVLogger.shared` for structured logs streamed to iPhone in real-time
- **No re-encoding video**: Always copy video codec; only remux container / transcode audio / convert subtitles
