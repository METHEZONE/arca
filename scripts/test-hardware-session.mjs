import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn } from "node:child_process";

const port = 4185;
const baseUrl = `http://127.0.0.1:${port}`;
const token = "hardware-regression-token";
const dataDir = await mkdtemp(join(tmpdir(), "arca-hardware-test-"));
let output = "";
let server;

function startServer() {
  output = "";
  server = spawn(process.execPath, ["node_modules/next/dist/bin/next", "dev", "-p", String(port)], {
    env: {
      ...process.env,
      ANALYSIS_PROVIDER: "demo",
      TRANSCRIPTION_PROVIDER: "demo",
      AUTO_PUSH_TARGETS: "none",
      ARCA_INGEST_TOKEN: token,
      ARCA_DATA_DIR: dataDir,
      DATABASE_URL: "",
      OPENAI_API_KEY: "",
      ELEVENLABS_API_KEY: "",
      ANTHROPIC_API_KEY: "",
      RESEND_API_KEY: "",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  server.stdout.on("data", (chunk) => { output += chunk; });
  server.stderr.on("data", (chunk) => { output += chunk; });
}

async function stopServer() {
  if (!server || server.exitCode !== null) return;
  server.kill("SIGTERM");
  await new Promise((resolve) => server.once("exit", resolve));
}

async function waitUntilReady() {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(baseUrl);
      if (response.status < 500) return;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error(`Next dev server did not become ready.\n${output.slice(-2000)}`);
}

async function upload({
  sessionId,
  deviceId,
  seq = 0,
  totalChunks = 1,
  offsetSec = 0,
  final = true,
  bytes = new Uint8Array([82, 73, 70, 70]),
}) {
  const form = new FormData();
  form.set("recording", new File([bytes], `${sessionId}-${seq}.wav`, { type: "audio/wav" }));
  form.set("sessionId", sessionId);
  form.set("deviceId", deviceId);
  form.set("seq", String(seq));
  form.set("totalChunks", String(totalChunks));
  form.set("offsetSec", String(offsetSec));
  form.set("final", String(final));
  const response = await fetch(`${baseUrl}/api/hardware/session/chunk`, {
    method: "POST",
    headers: { "x-arca-device-token": token },
    body: form,
  });
  return { status: response.status, body: await response.json() };
}

async function audio(sessionId, deviceId, seq, authToken = token) {
  const query = new URLSearchParams({ sessionId, deviceId });
  if (seq !== undefined) query.set("seq", String(seq));
  return fetch(`${baseUrl}/api/hardware/session/audio?${query}`, {
    headers: { "x-arca-device-token": authToken },
  });
}

try {
  startServer();
  await waitUntilReady();

  const concurrentId = `concurrent-${Date.now()}`;
  const concurrent = await Promise.all([
    upload({ sessionId: concurrentId, deviceId: "device-a" }),
    upload({ sessionId: concurrentId, deviceId: "device-a" }),
  ]);
  assert.deepEqual(concurrent.map((result) => result.status), [200, 200]);
  assert.equal(concurrent[0].body.memoryId, concurrent[1].body.memoryId);

  const outOfOrderId = `out-of-order-${Date.now()}`;
  const prematureFinal = await upload({
    sessionId: outOfOrderId,
    deviceId: "device-a",
    seq: 1,
    totalChunks: 2,
    offsetSec: 100,
  });
  assert.equal(prematureFinal.status, 409);
  assert.deepEqual(prematureFinal.body.missing, [0]);
  assert.equal((await upload({
    sessionId: outOfOrderId,
    deviceId: "device-a",
    seq: 0,
    totalChunks: 2,
    final: false,
  })).status, 200);
  assert.equal((await upload({
    sessionId: outOfOrderId,
    deviceId: "device-a",
    seq: 1,
    totalChunks: 2,
    offsetSec: 100,
  })).status, 200);

  const sharedId = `shared-${Date.now()}`;
  const deviceA = await upload({ sessionId: sharedId, deviceId: "device-a" });
  const deviceB = await upload({ sessionId: sharedId, deviceId: "device-b" });
  assert.notEqual(deviceA.body.memoryId, deviceB.body.memoryId);

  const mismatchId = `mismatch-${Date.now()}`;
  await upload({ sessionId: mismatchId, deviceId: "device-a", totalChunks: 2, final: false });
  const mismatch = await upload({
    sessionId: mismatchId,
    deviceId: "device-a",
    totalChunks: 3,
    final: false,
  });
  assert.equal(mismatch.status, 400);
  assert.match(mismatch.body.error, /totalChunks changed/);

  const poisonId = `metadata-poison-${Date.now()}`;
  const validFirst = new Uint8Array([82, 73, 70, 70, 10]);
  const rejectedSecond = new Uint8Array([82, 73, 70, 70, 11]);
  const validSecond = new Uint8Array([82, 73, 70, 70, 12]);
  assert.equal((await upload({
    sessionId: poisonId,
    deviceId: "device-a",
    seq: 0,
    totalChunks: 2,
    final: false,
    bytes: validFirst,
  })).status, 200);
  assert.equal((await upload({
    sessionId: poisonId,
    deviceId: "device-a",
    seq: 1,
    totalChunks: 3,
    final: false,
    bytes: rejectedSecond,
  })).status, 400);
  assert.equal((await upload({
    sessionId: poisonId,
    deviceId: "device-a",
    seq: 1,
    totalChunks: 2,
    offsetSec: 100,
    bytes: validSecond,
  })).status, 200);
  const poisonDownload = await audio(poisonId, "device-a", 1);
  assert.equal(poisonDownload.status, 200);
  assert.deepEqual(new Uint8Array(await poisonDownload.arrayBuffer()), validSecond);

  const durableId = `durable-audio-${Date.now()}`;
  const firstBytes = new Uint8Array([82, 73, 70, 70, 1, 2, 3]);
  const secondBytes = new Uint8Array([82, 73, 70, 70, 4, 5, 6]);
  assert.equal((await upload({
    sessionId: durableId,
    deviceId: "device-restart",
    seq: 0,
    totalChunks: 2,
    final: false,
    bytes: firstBytes,
  })).status, 200);

  // Simulate a function/app restart between chunks. Both transcript progress
  // and original audio must survive in the same persistent data directory.
  await stopServer();
  startServer();
  await waitUntilReady();
  assert.equal((await upload({
    sessionId: durableId,
    deviceId: "device-restart",
    seq: 1,
    totalChunks: 2,
    offsetSec: 100,
    bytes: secondBytes,
  })).status, 200);

  assert.equal((await audio(durableId, "device-restart", undefined, "wrong-token")).status, 401);
  const manifestResponse = await audio(durableId, "device-restart");
  assert.equal(manifestResponse.status, 200);
  const manifest = await manifestResponse.json();
  assert.equal(manifest.chunkCount, 2);
  assert.equal(manifest.totalBytes, firstBytes.length + secondBytes.length);
  const firstDownload = await audio(durableId, "device-restart", 0);
  assert.equal(firstDownload.status, 200);
  assert.deepEqual(new Uint8Array(await firstDownload.arrayBuffer()), firstBytes);

  const conflictId = `audio-conflict-${Date.now()}`;
  await upload({
    sessionId: conflictId,
    deviceId: "device-a",
    seq: 0,
    totalChunks: 2,
    final: false,
    bytes: firstBytes,
  });
  const changedRetry = await upload({
    sessionId: conflictId,
    deviceId: "device-a",
    seq: 0,
    totalChunks: 2,
    final: false,
    bytes: secondBytes,
  });
  assert.equal(changedRetry.status, 400);
  assert.match(changedRetry.body.error, /different bytes/);

  console.log("hardware session regression tests passed");
} finally {
  await stopServer();
  await rm(dataDir, { recursive: true, force: true });
}
