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

Plays content via AVPlayer. For non-native containers (MKV, AVI) or unsupported audio codecs (DTS, TrueHD), runs an on-device FFmpeg pipeline: remux to HLS, transcode audio to AAC, convert subtitles to WebVTT. Serves segments via a local HTTP server. Video is always copied bit-for-bit — never transcoded. PGS bitmap subtitles are extracted as timed PNG images and rendered as an overlay on top of the video player.

## Android TV

Plays content via ExoPlayer, which handles MKV, HEVC, DTS, TrueHD, PGS subtitles, and most formats natively. No processing pipeline needed.

## iPhone

Probes URLs (AVFoundation + FFmpeg fallback), shows track info with color-coded compatibility badges (green/yellow/red), lets the user select tracks, and casts. Not needed during playback.

## Compatibility

### Containers

| Format | Apple TV | Android TV |
|--------|----------|------------|
| MP4/MOV/M4V | Native | Native |
| HLS (.m3u8) | Native | Native |
| MKV | Remux to HLS | Native |
| WebM | Remux to HLS | Native |
| AVI | Remux to HLS | Native |

### Video Codecs

| Codec | Apple TV | Android TV |
|-------|----------|------------|
| H.264 | Native | Native |
| HEVC | Native | Native |
| HEVC Dolby Vision | Native (tone-mapped if display doesn't support DV) | Native |
| VP9 | Native (MP4 only) | Native |
| VP8 | Unsupported | Native |
| AV1 | Unsupported | Native |

### Audio Codecs

| Codec | Apple TV | Android TV |
|-------|----------|------------|
| AAC | Native | Native |
| MP3 | Native | Native |
| AC-3 (Dolby Digital) | Native | Native |
| E-AC-3 (Dolby Digital Plus) | Native | Native |
| DTS / DTS-HD | Transcode to AAC | Native |
| TrueHD | Transcode to AAC | Native |
| FLAC | Transcode to AAC | Native |
| Opus | Transcode to AAC | Native |
| Vorbis | Transcode to AAC | Native |
| PCM | Native | Native |

### Subtitle Formats

| Format | Apple TV | Android TV |
|--------|----------|------------|
| WebVTT | Native | Native |
| CEA-608/708 | Native | Native |
| mov_text (tx3g) | Native | Native |
| SRT | Convert to WebVTT | Native |
| ASS/SSA | Convert to WebVTT (styling lost) | Native |
| PGS (bitmap) | Bitmap overlay | Native |

### How CastTV compares

| Feature | CastTV (Apple TV) | CastTV (Android TV) | AirPlay | Chromecast | DLNA |
|---------|-------------------|---------------------|---------|------------|------|
| **Containers** |
| MP4/MOV/HLS | ✅ | ✅ | ✅ | ✅ | ✅ |
| MKV | 🔄 | ✅ | ❌ | ❌ | ⚠️ |
| WebM | 🔄 | ✅ | ❌ | ✅ | ⚠️ |
| AVI | 🔄 | ✅ | ❌ | ❌ | ⚠️ |
| **Video Codecs** |
| H.264 | ✅ | ✅ | ✅ | ✅ | ✅ |
| HEVC | ✅ | ✅ | ✅ | ⚠️ | ⚠️ |
| Dolby Vision | ✅ | ✅ | ✅ | ⚠️ | ⚠️ |
| VP9 | ✅ (MP4 only) | ✅ | ❌ | ✅ | ⚠️ |
| AV1 | ❌ | ✅ | ❌ | ✅ | ⚠️ |
| **Audio Codecs** |
| AAC / AC-3 / E-AC-3 | ✅ | ✅ | ✅ | ✅ | ✅ |
| DTS / DTS-HD | 🔄 | ✅ | ❌ | ❌ | ⚠️ |
| TrueHD / Atmos | 🔄 | ✅ | ❌ | ❌ | ⚠️ |
| FLAC | 🔄 | ✅ | ✅ | ✅ | ⚠️ |
| Opus | 🔄 | ✅ | ❌ | ✅ | ⚠️ |
| **Subtitles** |
| WebVTT / CEA-608 | ✅ | ✅ | ✅ | ✅ | ⚠️ |
| SRT | 🔄 | ✅ | ❌ | ✅ | ⚠️ |
| ASS/SSA | 🔄 | ✅ | ❌ | ❌ | ⚠️ |
| PGS (bitmap) | 🔄 | ✅ | ❌ | ❌ | ⚠️ |
| **Features** |
| E2E encrypted | ✅ | ✅ | ❌ | ❌ | ❌ |
| No account required | ✅ | ✅ | ❌ | ❌ | ✅ |
| Cross-platform remote | ✅ | ✅ | ❌ | ⚠️ | ⚠️ |
| Direct URL playback | ✅ | ✅ | ❌ | ❌ | ✅ |
| On-device remux | ✅ | ❌ (not needed) | ❌ | ❌ | ❌ |
| Video quality preserved | ✅ | ✅ | ✅ | ⚠️ | ✅ |

✅ Native  🔄 Processed on-device  ⚠️ Varies / partial  ❌ Unsupported

## Worker

Cloudflare Worker with Durable Objects. One Durable Object per room (per TV). Routes:

- `GET /` — landing page
- `GET /room/:code/status` — connection presence check
- `GET /room/:code/ws?role=appletv|androidtv|iphone` — WebSocket relay

The Android APK is served directly from GitHub Releases (`https://github.com/abadari3/CastTV/releases/latest/download/CastTV-AndroidTV.apk`).

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
