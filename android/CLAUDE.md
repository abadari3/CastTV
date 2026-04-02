# Android TV

Native Kotlin/Compose app for Android TV with ExoPlayer for media playback.

## Build System

- **Gradle** (Kotlin DSL): `build.gradle.kts`
- **Version catalog**: `gradle/libs.versions.toml` for dependency management
- **Compile SDK**: 34 (Android 14), **Min SDK**: 21 (Android 5.0)
- **Java target**: JDK 17

### Key Dependencies

| Library | Purpose |
|---------|---------|
| Media3 ExoPlayer 1.3.0 | Video playback (HLS, DASH, progressive) |
| OkHttp 4.12.0 | WebSocket client |
| Gson 2.10.1 | JSON serialization |
| ZXing 3.5.3 | QR code bitmap generation |
| Jetpack Compose (BOM 2024.02) | UI framework |
| Material3 + TV Material 1.0.0 | TV-optimized UI components |

## Project Structure

```
app/src/main/java/com/casttv/androidtv/
  MainActivity.kt          # App entry: pairing UI, WebSocket orchestration, intent routing
  ui/
    HomeScreen.kt           # Compose UI: QR code display, room code, connection status
  network/
    WebSocketClient.kt      # OkHttp WebSocket: encrypted messaging, auto-reconnect (2s delay)
    Messages.kt             # Sealed class CastMessage + MessageCodec (Gson-based JSON)
    NsdAdvertiser.kt        # mDNS/Bonjour advertising via NsdManager (matches tvOS BonjourAdvertiser)
  crypto/
    Encryption.kt           # AES-256-GCM via javax.crypto (cross-compatible with CryptoKit)
    QRCodeGenerator.kt      # ZXing QR bitmap + casttv:<room>:<key> format
  storage/
    PairingStorage.kt       # SharedPreferences: room code + encryption key (base64url)
    CastLogger.kt           # Thread-safe logging: in-memory (5000 entries) + file (1MB JSON lines)
  device/
    CapabilityDetector.kt   # Display (4K, HDR modes, refresh) + audio (channels, Atmos) detection
  player/
    PlayerActivity.kt       # ExoPlayer: fullscreen playback, DPAD controls, track selection
```

## Architecture

- **State**: `mutableStateOf()` for Compose reactivity
- **Async**: Kotlin coroutines with `lifecycleScope`, `Dispatchers.IO/Default`
- **Networking**: `StateFlow<ConnectionState>` + `SharedFlow<CastMessage>` from WebSocket
- **No remuxing needed**: ExoPlayer handles MKV, WebM, AVI natively (unlike AVPlayer on tvOS)

## ExoPlayer Configuration

- **Buffering**: Min/Max 20s, 32 MB target, 1s pre-buffer for fast startup
- **Network**: OkHttp data source, 30s connect/read timeouts, cross-protocol redirects
- **Rendering**: Hardware decoders with software fallback
- **Controls**: DPAD seek (10s tap, 30s short hold, 1m medium, 5m long hold)
- **Natively supported**: MKV, MP4, WebM, H.264, HEVC, VP8, VP9, AAC, OPUS, FLAC, DTS, TrueHD, E-AC3, SRT, ASS, PGS, WebVTT

## Key Differences from Apple TV

- **No FFmpeg pipeline**: ExoPlayer supports almost all codecs/containers natively
- **No local HTTP server**: ExoPlayer plays files directly (no HLS remux needed)
- **SharedPreferences**: Instead of Keychain for key storage
- **Manifest declarations**: `leanback` feature required, touchscreen optional
- **Max 1 TV per room**: Enforced server-side (409 if second TV connects)
