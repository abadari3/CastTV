# CastTV

Cast video URLs to your Apple TV or Android TV. An iPhone app acts as a remote control — probe URLs, check compatibility, select tracks, and cast. The TV plays the video directly from the source.

## How it works

```
iPhone ──encrypted WebSocket──> Cloudflare Worker (relay) <──encrypted WebSocket── TV
                                                                                   │
                                                                          fetches video
                                                                          directly from
                                                                          source URL
```

- All messages are end-to-end encrypted (AES-256-GCM). The relay sees only opaque bytes.
- Video streams go directly from source to TV. Only small control messages (~200 bytes) pass through the relay.
- Pair by scanning a QR code. No accounts, no sign-in.

## Project structure

```
apple/
├── CastTV/              # Xcode project (iOS + tvOS targets)
├── CastTVShared/        # Swift Package — messages, encryption, WebSocket, compatibility engine
└── FFmpegKit/           # FFmpeg wrapper — probing, remuxing, subtitle conversion

android/                 # Android TV app (Kotlin, ExoPlayer)

worker/
└── src/index.js         # Cloudflare Worker + Durable Object relay
```

## Apple TV

Plays content via AVPlayer. For non-native containers (MKV, AVI) or unsupported audio codecs (DTS, TrueHD), runs an on-device FFmpeg pipeline: remux to HLS, transcode audio to AAC, convert subtitles to WebVTT. Serves segments via a local HTTP server. Video is always copied bit-for-bit — never transcoded.

## Android TV

Plays content via ExoPlayer, which handles MKV, HEVC, DTS, TrueHD, PGS subtitles, and most formats natively. No processing pipeline needed.

## iPhone

Probes URLs (AVFoundation + FFmpeg fallback), shows track info with color-coded compatibility badges (green/yellow/red), lets the user select tracks, and casts. Not needed during playback.

## Compatibility

| | Apple TV | Android TV |
|---|---|---|
| MP4/MOV/HLS | Native | Native |
| MKV/WebM/AVI | Remux to HLS | Native |
| H.264/HEVC | Native | Native |
| VP9/AV1 | Unsupported | Native |
| AAC/AC-3/E-AC-3 | Native | Native |
| DTS/TrueHD/FLAC | Transcode to AAC | Native |
| WebVTT/CEA-608 | Native | Native |
| SRT/ASS | Convert to WebVTT | Native |
| PGS (bitmap) | Unsupported | Native |

## Worker

Cloudflare Worker with Durable Objects. One Durable Object per room (per TV). Routes:

- `GET /room/:code/status` — connection presence check
- `GET /room/:code/ws?role=appletv|androidtv|iphone` — WebSocket relay
- `GET /download/android` — APK download from R2

Room codes are 6 characters from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`. Rate-limited. Room code length validated server-side.

## Setup

**Worker:**
```sh
cd worker
npx wrangler deploy
```

**Apple (iOS + tvOS):**
Open `apple/CastTV/CastTV.xcodeproj` in Xcode. Build the iOS target for iPhone, tvOS target for Apple TV.

**Android TV:**
Open `android/` in Android Studio. Build and install.

## Pairing

1. Open CastTV on your TV — it displays a QR code
2. Open CastTV on your iPhone — tap + and scan the QR code
3. Done. The iPhone saves the pairing and shows the TV in its device list.

The QR code encodes `casttv:ROOMCODE:ENCRYPTION_KEY`. Both devices connect to the same relay room. All subsequent communication is encrypted with the shared key.
