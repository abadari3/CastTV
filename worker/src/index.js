/**
 * CastTV Cloudflare Worker
 *
 * Routes:
 *   GET  /                    — landing page
 *   GET  /altstore.json       — AltStore source manifest (auto-derived from GH Releases)
 *   GET  /room/:code/status   — returns whether a TV is connected
 *   GET  /room/:code/ws       — upgrades to WebSocket, requires ?role=appletv|androidtv|iphone
 *
 * Durable Object "Room" manages per-room WebSocket relay.
 */

// In-memory rate limit (resets on cold start — defense-in-depth only)
const statusRateLimit = new Map(); // IP -> { count, resetAt }
const STATUS_RATE_LIMIT = 30; // max requests per window
const STATUS_RATE_WINDOW = 60000; // 1 minute

function checkStatusRateLimit(ip) {
  const now = Date.now();
  let entry = statusRateLimit.get(ip);
  if (!entry || now > entry.resetAt) {
    entry = { count: 0, resetAt: now + STATUS_RATE_WINDOW };
  }
  entry.count++;
  statusRateLimit.set(ip, entry);
  // Prune stale entries periodically
  if (statusRateLimit.size > 10000) {
    for (const [key, val] of statusRateLimit) {
      if (now > val.resetAt) statusRateLimit.delete(key);
    }
  }
  return entry.count <= STATUS_RATE_LIMIT;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    // CORS headers for all responses
    const corsHeaders = {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type",
    };

    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders });
    }

    // Route: GET /
    if (path === "/") {
      return new Response(LANDING_PAGE_HTML, {
        headers: { "Content-Type": "text/html; charset=utf-8", ...corsHeaders },
      });
    }

    // Route: GET /altstore.json
    if (path === "/altstore.json") {
      return handleAltStoreSource(corsHeaders);
    }

    // Route: GET /room/:code/status
    const statusMatch = path.match(/^\/room\/([A-Za-z0-9]+)\/status$/);
    if (statusMatch) {
      if (statusMatch[1].length !== 6) {
        return new Response(JSON.stringify({ error: "Invalid room code" }), {
          status: 400,
          headers: { "Content-Type": "application/json", ...corsHeaders },
        });
      }
      const ip = request.headers.get("CF-Connecting-IP") || "unknown";
      if (!checkStatusRateLimit(ip)) {
        return new Response(JSON.stringify({ error: "Too many requests" }), {
          status: 429,
          headers: { "Content-Type": "application/json", "Retry-After": "60", ...corsHeaders },
        });
      }
      const code = statusMatch[1].toUpperCase();
      const roomId = env.ROOM.idFromName(code);
      const room = env.ROOM.get(roomId);
      const res = await room.fetch(new Request("http://internal/status"));
      const body = await res.json();
      return new Response(JSON.stringify(body), {
        headers: { "Content-Type": "application/json", ...corsHeaders },
      });
    }

    // Route: GET /room/:code/ws
    const wsMatch = path.match(/^\/room\/([A-Za-z0-9]+)\/ws$/);
    if (wsMatch) {
      if (wsMatch[1].length !== 6) {
        return new Response(JSON.stringify({ error: "Invalid room code" }), {
          status: 400,
          headers: { "Content-Type": "application/json", ...corsHeaders },
        });
      }
      const code = wsMatch[1].toUpperCase();
      const role = url.searchParams.get("role");

      if (!role || !["appletv", "androidtv", "iphone"].includes(role)) {
        return new Response(
          JSON.stringify({
            error:
              "Missing or invalid role parameter. Use ?role=appletv, ?role=androidtv, or ?role=iphone",
          }),
          { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );
      }

      if (request.headers.get("Upgrade") !== "websocket") {
        return new Response(JSON.stringify({ error: "Expected WebSocket upgrade" }), {
          status: 426,
          headers: { "Content-Type": "application/json", ...corsHeaders },
        });
      }

      const roomId = env.ROOM.idFromName(code);
      const room = env.ROOM.get(roomId);
      // Forward the request with role info
      const roomUrl = new URL(`http://internal/ws?role=${role}`);
      return room.fetch(
        new Request(roomUrl, {
          headers: request.headers,
        })
      );
    }

    return new Response(JSON.stringify({ error: "Not found" }), {
      status: 404,
      headers: { "Content-Type": "application/json", ...corsHeaders },
    });
  },
};

/**
 * Durable Object: Room
 *
 * Manages WebSocket connections for a single room.
 * Tracks device roles and relays messages between TV and iPhone clients.
 */
export class Room {
  constructor(state, env) {
    this.state = state;
  }

  /**
   * Rebuild the connections list from hibernation-safe WebSocket storage.
   * Tags assigned via acceptWebSocket() survive hibernation; the in-memory
   * Map does not.
   */
  getConnections() {
    const conns = new Map();
    for (const ws of this.state.getWebSockets()) {
      const tags = this.state.getTags(ws);
      const role = tags[0] || "unknown";
      conns.set(ws, { role });
    }
    return conns;
  }

  async fetch(request) {
    const url = new URL(request.url);

    if (url.pathname === "/status") {
      return this.handleStatus();
    }

    if (url.pathname === "/ws") {
      return this.handleWebSocket(request, url);
    }

    return new Response("Not found", { status: 404 });
  }

  handleStatus() {
    let appleTvConnected = false;
    let iphoneConnected = false;
    let connectionCount = 0;

    for (const [, meta] of this.getConnections()) {
      connectionCount++;
      if (meta.role === "appletv" || meta.role === "androidtv") appleTvConnected = true;
      if (meta.role === "iphone") iphoneConnected = true;
    }

    return new Response(
      JSON.stringify({
        appleTvConnected,
        iphoneConnected,
        connectionCount,
      }),
      { headers: { "Content-Type": "application/json" } }
    );
  }

  handleWebSocket(request, url) {
    const role = url.searchParams.get("role");
    const connections = this.getConnections();
    console.log(
      `handleWebSocket: role=${role}, existing connections: ${connections.size} (${[...connections.values()].map((m) => m.role).join(", ")})`
    );

    // Room code collision check: reject if a TV is already connected
    // and another TV tries to join
    if (role === "appletv" || role === "androidtv") {
      for (const [, meta] of connections) {
        if (meta.role === "appletv" || meta.role === "androidtv") {
          return new Response(JSON.stringify({ error: "Room already has a TV connected" }), {
            status: 409,
            headers: { "Content-Type": "application/json" },
          });
        }
      }
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);

    this.state.acceptWebSocket(server, [role]);

    // Notify existing connections about the new device
    const joinMsg = JSON.stringify({
      type: "device_joined",
      role,
      timestamp: new Date().toISOString(),
    });
    for (const [ws] of connections) {
      try {
        ws.send(joinMsg);
      } catch {}
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, message) {
    const connections = this.getConnections();
    const senderMeta = connections.get(ws);
    const msgPreview =
      typeof message === "string" ? message.substring(0, 50) : `[binary ${message.byteLength}b]`;
    console.log(
      `webSocketMessage from ${senderMeta?.role || "unknown"}: ${msgPreview}... (${connections.size} connections)`
    );

    if (!senderMeta) {
      console.log("webSocketMessage: sender not found in connections, dropping");
      return;
    }

    // Relay to all other connections in the room
    let relayed = 0;
    for (const [otherWs, otherMeta] of connections) {
      if (otherWs !== ws) {
        try {
          otherWs.send(message);
          relayed++;
          console.log(`  relayed to ${otherMeta.role}`);
        } catch (e) {
          console.log(`  relay to ${otherMeta.role} failed: ${e}`);
        }
      }
    }
    console.log(`webSocketMessage: relayed to ${relayed} connections`);
  }

  async webSocketClose(ws, code, reason, wasClean) {
    const connections = this.getConnections();
    const meta = connections.get(ws);

    if (meta) {
      // Notify remaining connections
      const leaveMsg = JSON.stringify({
        type: "device_left",
        role: meta.role,
        timestamp: new Date().toISOString(),
      });
      for (const [otherWs] of connections) {
        if (otherWs !== ws) {
          try {
            otherWs.send(leaveMsg);
          } catch {}
        }
      }
    }

    try {
      ws.close(code, reason);
    } catch {}
  }

  async webSocketError(ws, error) {
    const connections = this.getConnections();
    const meta = connections.get(ws);

    if (meta) {
      const leaveMsg = JSON.stringify({
        type: "device_left",
        role: meta.role,
        timestamp: new Date().toISOString(),
      });
      for (const [otherWs] of connections) {
        if (otherWs !== ws) {
          try {
            otherWs.send(leaveMsg);
          } catch {}
        }
      }
    }

    try {
      ws.close(1011, "WebSocket error");
    } catch {}
  }
}

/**
 * Build an AltStore source manifest from the latest GitHub Release.
 * Reads the iOS .ipa asset, returns a source pointing at it.
 * Cached at the edge for 5 minutes to avoid hitting the GitHub API rate limit.
 */
async function handleAltStoreSource(corsHeaders) {
  const cache = caches.default;
  const cacheKey = new Request("https://cast.anandabadari.com/altstore.json");
  const cached = await cache.match(cacheKey);
  if (cached) return cached;

  const ghResponse = await fetch("https://api.github.com/repos/abadari3/CastTV/releases/latest", {
    headers: { "User-Agent": "casttv-worker", Accept: "application/vnd.github+json" },
  });
  if (!ghResponse.ok) {
    return new Response(
      JSON.stringify({ error: "Failed to fetch latest release", status: ghResponse.status }),
      { status: 502, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
  }
  const release = await ghResponse.json();
  const iosAsset = release.assets?.find((a) => a.name === "CastTV-iOS.ipa");

  const source = {
    name: "CastTV",
    identifier: "com.anandabadari.casttv.source",
    sourceURL: "https://cast.anandabadari.com/altstore.json",
    apps: iosAsset
      ? [
          {
            name: "CastTV",
            bundleIdentifier: "com.anandabadari.casttv",
            developerName: "Anand Badari",
            subtitle: "Cast any video URL to your Apple TV or Android TV",
            version: release.tag_name.replace(/^v/, ""),
            versionDate: release.published_at,
            versionDescription: release.body || "",
            downloadURL: iosAsset.browser_download_url,
            localizedDescription:
              "Cast video URLs to your Apple TV or Android TV. The iPhone is the remote. End-to-end encrypted (AES-256-GCM). No accounts, no sign-in. Pair by scanning a QR code; video streams direct from source to TV.",
            iconURL:
              "https://raw.githubusercontent.com/abadari3/CastTV/main/apple/CastTV/iOS/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
            tintColor: "0a7cff",
            size: iosAsset.size,
          },
        ]
      : [],
  };

  const response = new Response(JSON.stringify(source, null, 2), {
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "public, max-age=300",
      ...corsHeaders,
    },
  });
  // Only cache when we actually have an iOS asset; avoids caching the empty case
  if (iosAsset) {
    await cache.put(cacheKey, response.clone());
  }
  return response;
}

const LANDING_PAGE_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>CastTV — Cast any video to your TV</title>
<meta name="description" content="Cast video URLs from your iPhone to Apple TV or Android TV. End-to-end encrypted. No accounts.">
<style>
  :root {
    color-scheme: light dark;
    --bg: #fff;
    --fg: #111;
    --muted: #666;
    --border: #e5e5e5;
    --accent: #0a7cff;
    --code-bg: #f5f5f7;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0c0c0e;
      --fg: #f5f5f7;
      --muted: #9a9a9f;
      --border: #2a2a2e;
      --accent: #2f9bff;
      --code-bg: #1a1a1d;
    }
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; }
  body {
    background: var(--bg);
    color: var(--fg);
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, sans-serif;
    line-height: 1.55;
    -webkit-font-smoothing: antialiased;
  }
  main { max-width: 720px; margin: 0 auto; padding: 64px 24px 96px; }
  header { text-align: center; margin-bottom: 56px; }
  h1 { font-size: 56px; margin: 0 0 12px; letter-spacing: -0.03em; font-weight: 700; }
  .tagline { font-size: 20px; color: var(--muted); margin: 0; }
  h2 { font-size: 22px; margin: 48px 0 16px; letter-spacing: -0.01em; }
  p { margin: 0 0 16px; }
  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }
  .downloads { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; margin: 16px 0 0; }
  .btn {
    display: block;
    padding: 16px 20px;
    border: 1px solid var(--border);
    border-radius: 12px;
    color: var(--fg);
    text-decoration: none;
    transition: border-color 0.15s, transform 0.05s;
  }
  .btn:hover { border-color: var(--accent); text-decoration: none; }
  .btn:active { transform: scale(0.98); }
  .btn-label { font-weight: 600; font-size: 15px; }
  .btn-sub { font-size: 13px; color: var(--muted); margin-top: 2px; }
  ol { padding-left: 24px; }
  ol li { margin-bottom: 8px; }
  code { background: var(--code-bg); padding: 2px 6px; border-radius: 4px; font-size: 13px; font-family: ui-monospace, "SF Mono", Menlo, monospace; }
  .diagram {
    background: var(--code-bg);
    border-radius: 12px;
    padding: 20px;
    font-family: ui-monospace, "SF Mono", Menlo, monospace;
    font-size: 12px;
    line-height: 1.5;
    overflow-x: auto;
    white-space: pre;
    color: var(--muted);
  }
  footer { margin-top: 64px; padding-top: 24px; border-top: 1px solid var(--border); color: var(--muted); font-size: 14px; text-align: center; }
</style>
</head>
<body>
<main>
  <header>
    <h1>CastTV</h1>
    <p class="tagline">Cast any video URL to your Apple TV or Android TV.</p>
  </header>

  <section>
    <h2>How it works</h2>
    <p>Your iPhone is the remote. Pair with a TV by scanning a QR code, paste a video URL, and the TV plays it directly from the source. Everything between your devices is end-to-end encrypted (AES-256-GCM). No accounts, no sign-in.</p>
    <div class="diagram">iPhone ──encrypted WebSocket──&gt; relay &lt;──encrypted WebSocket── TV
                                          │
                                  video streams direct
                                  from source to TV</div>
  </section>

  <section>
    <h2>Download</h2>
    <div class="downloads">
      <a class="btn" href="altstore://source?url=https%3A%2F%2Fcast.anandabadari.com%2Faltstore.json">
        <div class="btn-label">iPhone — AltStore</div>
        <div class="btn-sub">Tap to add source &amp; install</div>
      </a>
      <a class="btn" href="https://github.com/abadari3/CastTV/releases/latest/download/CastTV-iOS.ipa">
        <div class="btn-label">iPhone — direct</div>
        <div class="btn-sub">CastTV-iOS.ipa (sideload)</div>
      </a>
      <a class="btn" href="https://github.com/abadari3/CastTV/releases/latest/download/CastTV-tvOS.ipa">
        <div class="btn-label">Apple TV</div>
        <div class="btn-sub">CastTV-tvOS.ipa (sideload via Xcode)</div>
      </a>
      <a class="btn" href="https://github.com/abadari3/CastTV/releases/latest/download/CastTV-AndroidTV.apk">
        <div class="btn-label">Android TV</div>
        <div class="btn-sub">CastTV-AndroidTV.apk</div>
      </a>
    </div>
  </section>

  <section>
    <h2>Pair a TV</h2>
    <ol>
      <li>Open CastTV on your TV — it displays a QR code.</li>
      <li>Open CastTV on your iPhone — tap <strong>+</strong> and scan the QR code.</li>
      <li>The TV appears in your iPhone's device list. Done.</li>
    </ol>
  </section>

  <section>
    <h2>Compatibility</h2>
    <p>Plays MP4, HLS, MKV, WebM, AVI. H.264, HEVC (incl. Dolby Vision), VP9, AV1 on Android. WebVTT, SRT, ASS, and PGS bitmap subtitles. Apple TV remuxes non-native containers on-device — video is always copied bit-for-bit, never transcoded.</p>
    <p>Full compatibility tables on <a href="https://github.com/abadari3/CastTV#compatibility">GitHub</a>.</p>
  </section>

  <footer>
    <a href="https://github.com/abadari3/CastTV">Source on GitHub</a>
  </footer>
</main>
</body>
</html>`;
