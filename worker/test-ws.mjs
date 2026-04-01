/**
 * Quick integration test for the CastTV worker.
 *
 * Usage:
 *   1. Start the worker:  npm run dev
 *   2. In another terminal: node test-ws.mjs
 *
 * Tests:
 *   - Status endpoint (empty room)
 *   - Two WebSocket clients connect (appletv + iphone)
 *   - Messages relay between them
 *   - Status endpoint (both connected)
 *   - Disconnect notifications
 */

const BASE = "http://localhost:8787";
const WS_BASE = "ws://localhost:8787";
const ROOM = "TESTROOM";

async function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function test() {
  console.log("--- Test 1: Status of empty room ---");
  const statusRes = await fetch(`${BASE}/room/${ROOM}/status`);
  const status = await statusRes.json();
  console.log("Status:", status);
  assert(!status.appleTvConnected, "Apple TV should not be connected");
  assert(!status.iphoneConnected, "iPhone should not be connected");
  console.log("PASS\n");

  console.log("--- Test 2: Connect Apple TV ---");
  const appleTV = new WebSocket(`${WS_BASE}/room/${ROOM}/ws?role=appletv`);
  const atvMessages = [];
  appleTV.onmessage = (e) => atvMessages.push(JSON.parse(e.data));
  await waitForOpen(appleTV);
  console.log("Apple TV connected");
  console.log("PASS\n");

  console.log("--- Test 3: Connect iPhone ---");
  const iphone = new WebSocket(`${WS_BASE}/room/${ROOM}/ws?role=iphone`);
  const iphoneMessages = [];
  iphone.onmessage = (e) => iphoneMessages.push(JSON.parse(e.data));
  await waitForOpen(iphone);
  console.log("iPhone connected");

  // Wait for join notifications
  await sleep(100);
  console.log("Apple TV received:", atvMessages);
  assert(atvMessages.some((m) => m.type === "device_joined" && m.role === "iphone"), "Apple TV should see iPhone join");
  console.log("PASS\n");

  console.log("--- Test 4: Status with both connected ---");
  const statusRes2 = await fetch(`${BASE}/room/${ROOM}/status`);
  const status2 = await statusRes2.json();
  console.log("Status:", status2);
  assert(status2.appleTvConnected, "Apple TV should be connected");
  assert(status2.iphoneConnected, "iPhone should be connected");
  assert(status2.connectionCount === 2, "Should have 2 connections");
  console.log("PASS\n");

  console.log("--- Test 5: Relay message iPhone → Apple TV ---");
  const testMsg = JSON.stringify({ type: "play", url: "https://example.com/video.mp4" });
  iphone.send(testMsg);
  await sleep(100);
  console.log("Apple TV received:", atvMessages);
  assert(atvMessages.some((m) => m.type === "play"), "Apple TV should receive play message");
  console.log("PASS\n");

  console.log("--- Test 6: Relay message Apple TV → iPhone ---");
  const capsMsg = JSON.stringify({ type: "capabilities", resolution: "4K", hdr: true });
  appleTV.send(capsMsg);
  await sleep(100);
  console.log("iPhone received:", iphoneMessages);
  assert(iphoneMessages.some((m) => m.type === "capabilities"), "iPhone should receive capabilities message");
  console.log("PASS\n");

  console.log("--- Test 7: Disconnect notification ---");
  iphone.close();
  await sleep(200);
  console.log("Apple TV received after iPhone disconnect:", atvMessages);
  assert(atvMessages.some((m) => m.type === "device_left" && m.role === "iphone"), "Apple TV should see iPhone leave");
  console.log("PASS\n");

  appleTV.close();
  console.log("All tests passed!");
  process.exit(0);
}

function waitForOpen(ws) {
  return new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = (e) => reject(new Error("WebSocket error: " + e.message));
  });
}

function assert(condition, msg) {
  if (!condition) {
    console.error("FAIL:", msg);
    process.exit(1);
  }
}

test().catch((e) => {
  console.error("Test error:", e);
  process.exit(1);
});
