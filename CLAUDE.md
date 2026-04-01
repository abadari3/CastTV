# CastTV

A cross-platform media casting system. An iPhone app sends media URLs to TV apps (Apple TV / Android TV) for playback, with end-to-end encryption and no account required.

## Architecture

```
iPhone (iOS)  ──WebSocket──▶  Cloudflare Worker (relay)  ◀──WebSocket──  TV (tvOS / Android TV)
                                 (Durable Objects)
```

- **All communication** goes through the Cloudflare Worker relay via encrypted WebSocket
- **No direct peer-to-peer connections** — the relay forwards messages between devices
- **Bonjour (mDNS)** is used only for local network discovery, not data transfer

## Pairing Flow

1. TV generates a 6-character room code + AES-256 encryption key
2. TV encodes both into a QR code: `casttv:<ROOMCODE>:<base64url-key>`
3. iPhone scans QR (or discovers TV via Bonjour on local network)
4. Both connect to the relay's WebSocket at `/room/{CODE}/ws?role=<role>`
5. All messages are encrypted client-side with AES-256-GCM before sending

## Message Protocol

JSON messages over WebSocket with `type`/`action` field routing:

| Message | Direction | Purpose |
|---------|-----------|---------|
| `PlayMessage` | iPhone → TV | URL + subtitle URL + track selection + processing requirements |
| `CapabilitiesMessage` | TV → iPhone | Device model, display (resolution, HDR), audio capabilities |
| `ErrorMessage` | TV → iPhone | Playback errors |
| `LogMessage` | TV → iPhone | Real-time streaming logs |
| `device_joined/left` | Relay → All | System messages (unencrypted) |

## Project Structure

```
apple/          # iOS + tvOS apps (Swift/SwiftUI)
android/        # Android TV app (Kotlin/Compose)
worker/         # Cloudflare Worker relay server (JavaScript)
scripts/        # Build scripts (FFmpeg compilation)
```

See each subdirectory's CLAUDE.md for platform-specific details.

## Encryption

- **Algorithm**: AES-256-GCM (authenticated encryption)
- **Wire format**: base64(nonce[12] + ciphertext + tag[16])
- **Key sharing**: Via QR code or Bonjour TXT record (local network only)
- **Relay is blind**: Worker only sees base64-encoded ciphertext

## Key Design Decisions

- **No accounts**: Pairing is device-to-device via shared secret
- **Relay over P2P**: Avoids NAT traversal issues, works across networks
- **iPhone decides processing**: iPhone probes media, checks TV capabilities, tells TV what needs remuxing/transcoding
- **Video is never re-encoded**: Only remuxed to HLS if container is unsupported; audio/subtitles transcoded as needed
