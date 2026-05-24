import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

const noEnv = {};
const req = (path, opts = {}) => new Request(`https://example.com${path}`, opts);

test("GET / returns landing page HTML", async () => {
  const res = await worker.fetch(req("/"), noEnv);
  assert.equal(res.status, 200);
  assert.match(res.headers.get("content-type"), /text\/html/);
  const body = await res.text();
  assert.match(body, /CastTV/);
});

test("OPTIONS returns 204 with CORS headers", async () => {
  const res = await worker.fetch(req("/", { method: "OPTIONS" }), noEnv);
  assert.equal(res.status, 204);
  assert.equal(res.headers.get("access-control-allow-origin"), "*");
});

test("GET /room/ABC/status rejects short room code", async () => {
  const res = await worker.fetch(req("/room/ABC/status"), noEnv);
  assert.equal(res.status, 400);
  const body = await res.json();
  assert.equal(body.error, "Invalid room code");
});

test("GET /room/ABCDEF/ws without role returns 400", async () => {
  const res = await worker.fetch(req("/room/ABCDEF/ws"), noEnv);
  assert.equal(res.status, 400);
});

test("GET /room/ABCDEF/ws with invalid role returns 400", async () => {
  const res = await worker.fetch(req("/room/ABCDEF/ws?role=desktop"), noEnv);
  assert.equal(res.status, 400);
});

test("GET /room/ABC/ws rejects short room code", async () => {
  const res = await worker.fetch(req("/room/ABC/ws?role=iphone"), noEnv);
  assert.equal(res.status, 400);
});

test("GET /room/ABCDEF/ws without Upgrade header returns 426", async () => {
  const res = await worker.fetch(req("/room/ABCDEF/ws?role=iphone"), noEnv);
  assert.equal(res.status, 426);
});

test("GET /nonexistent returns 404", async () => {
  const res = await worker.fetch(req("/nonexistent"), noEnv);
  assert.equal(res.status, 404);
});
