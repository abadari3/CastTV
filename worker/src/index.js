/**
 * CastTV Cloudflare Worker
 *
 * Routes:
 *   GET  /download/android     — serves Android TV APK from R2
 *   GET  /room/:code/status   — returns whether a TV is connected
 *   GET  /room/:code/ws       — upgrades to WebSocket, requires ?role=appletv|androidtv|iphone
 *
 * Durable Object "Room" manages per-room WebSocket relay.
 */

// In-memory rate limit (resets on cold start — defense-in-depth only)
const statusRateLimit = new Map(); // IP -> { count, resetAt }
const STATUS_RATE_LIMIT = 30;     // max requests per window
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

    // Route: GET /download/android
    if (path === "/download/android") {
      const object = await env.ASSETS.get("android/casttv.apk");
      if (!object) {
        return new Response(JSON.stringify({ error: "APK not found" }), {
          status: 404, headers: { "Content-Type": "application/json", ...corsHeaders },
        });
      }
      return new Response(object.body, {
        headers: {
          "Content-Type": "application/vnd.android.package-archive",
          "Content-Disposition": 'attachment; filename="CastTV.apk"',
          "Content-Length": object.size,
          ...corsHeaders,
        },
      });
    }

    // Route: GET /room/:code/status
    const statusMatch = path.match(/^\/room\/([A-Za-z0-9]+)\/status$/);
    if (statusMatch) {
      if (statusMatch[1].length !== 6) {
        return new Response(
          JSON.stringify({ error: "Invalid room code" }),
          { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );
      }
      const ip = request.headers.get("CF-Connecting-IP") || "unknown";
      if (!checkStatusRateLimit(ip)) {
        return new Response(
          JSON.stringify({ error: "Too many requests" }),
          { status: 429, headers: { "Content-Type": "application/json", "Retry-After": "60", ...corsHeaders } }
        );
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
        return new Response(
          JSON.stringify({ error: "Invalid room code" }),
          { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );
      }
      const code = wsMatch[1].toUpperCase();
      const role = url.searchParams.get("role");

      if (!role || !["appletv", "androidtv", "iphone"].includes(role)) {
        return new Response(
          JSON.stringify({ error: "Missing or invalid role parameter. Use ?role=appletv, ?role=androidtv, or ?role=iphone" }),
          { status: 400, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );
      }

      if (request.headers.get("Upgrade") !== "websocket") {
        return new Response(
          JSON.stringify({ error: "Expected WebSocket upgrade" }),
          { status: 426, headers: { "Content-Type": "application/json", ...corsHeaders } }
        );
      }

      const roomId = env.ROOM.idFromName(code);
      const room = env.ROOM.get(roomId);
      // Forward the request with role info
      const roomUrl = new URL(`http://internal/ws?role=${role}`);
      return room.fetch(new Request(roomUrl, {
        headers: request.headers,
      }));
    }

    return new Response(
      JSON.stringify({ error: "Not found" }),
      { status: 404, headers: { "Content-Type": "application/json", ...corsHeaders } }
    );
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
    console.log(`handleWebSocket: role=${role}, existing connections: ${connections.size} (${[...connections.values()].map(m => m.role).join(", ")})`);

    // Room code collision check: reject if a TV is already connected
    // and another TV tries to join
    if (role === "appletv" || role === "androidtv") {
      for (const [, meta] of connections) {
        if (meta.role === "appletv" || meta.role === "androidtv") {
          return new Response(
            JSON.stringify({ error: "Room already has a TV connected" }),
            { status: 409, headers: { "Content-Type": "application/json" } }
          );
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
      try { ws.send(joinMsg); } catch {}
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, message) {
    const connections = this.getConnections();
    const senderMeta = connections.get(ws);
    const msgPreview = typeof message === "string" ? message.substring(0, 50) : `[binary ${message.byteLength}b]`;
    console.log(`webSocketMessage from ${senderMeta?.role || "unknown"}: ${msgPreview}... (${connections.size} connections)`);

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
          try { otherWs.send(leaveMsg); } catch {}
        }
      }
    }

    try { ws.close(code, reason); } catch {}
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
          try { otherWs.send(leaveMsg); } catch {}
        }
      }
    }

    try { ws.close(1011, "WebSocket error"); } catch {}
  }
}
