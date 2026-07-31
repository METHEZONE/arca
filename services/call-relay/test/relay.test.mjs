/**
 * End-to-end check of the relay: two signaling clients must pair and swap public
 * keys, and two UDP sockets must be able to reach each other through the media
 * port using the same envelope layout CallTransport.swift writes.
 *
 * Run: node test/relay.test.mjs   (server must NOT already be on these ports)
 */

import { spawn } from 'node:child_process';
import dgram from 'node:dgram';
import crypto from 'node:crypto';
import WebSocket from 'ws';
import assert from 'node:assert/strict';

const SIGNALING_PORT = 19080;
const MEDIA_PORT = 19081;
const TOKEN_SIZE = 16;

const server = spawn(process.execPath, ['server.js'], {
  env: { ...process.env, SIGNALING_PORT: String(SIGNALING_PORT), MEDIA_PORT: String(MEDIA_PORT) },
  stdio: ['ignore', 'pipe', 'inherit'],
});
server.stdout.on('data', (chunk) => process.stdout.write(`  [srv] ${chunk}`));

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const failures = [];

function check(name, fn) {
  try {
    fn();
    console.log(`ok   ${name}`);
  } catch (error) {
    failures.push(name);
    console.log(`FAIL ${name}: ${error.message}`);
  }
}

/** Mirrors CallTransport.swift: type(1) ‖ token(16) ‖ side(1) ‖ payload. */
function envelope(type, token, side, payload = Buffer.alloc(0)) {
  return Buffer.concat([Buffer.from([type]), token, Buffer.from([side]), payload]);
}

function open(room, side, publicKey) {
  const socket = new WebSocket(`ws://127.0.0.1:${SIGNALING_PORT}/call`);
  const inbox = [];
  socket.on('message', (raw) => inbox.push(JSON.parse(raw.toString())));
  return new Promise((resolve) => {
    socket.on('open', () => {
      socket.send(JSON.stringify({ type: 'join', room, side, publicKey }));
      resolve({ socket, inbox });
    });
  });
}

await sleep(700);

// --- signaling ------------------------------------------------------------
const roomCode = 'K7M2QD';
const caller = await open(roomCode, 'caller', 'CALLER_PUBKEY');
await sleep(150);

check('caller is told which side it got', () => {
  assert.equal(caller.inbox[0].type, 'joined');
  assert.equal(caller.inbox[0].side, 'caller');
});

check('caller alone is not paired', () => {
  assert.equal(caller.inbox.find((m) => m.type === 'peer-ready'), undefined);
});

const callee = await open(roomCode, 'callee', 'CALLEE_PUBKEY');
await sleep(200);

check('both sides receive the peer public key on pairing', () => {
  const toCaller = caller.inbox.find((m) => m.type === 'peer-ready');
  const toCallee = callee.inbox.find((m) => m.type === 'peer-ready');
  assert.equal(toCaller?.publicKey, 'CALLEE_PUBKEY');
  assert.equal(toCallee?.publicKey, 'CALLER_PUBKEY');
});

const duplicate = await open(roomCode, 'caller', 'INTRUDER');
await sleep(150);
check('a taken side is refused', () => {
  assert.equal(duplicate.inbox[0].type, 'room-full');
});
duplicate.socket.close();

// --- media relay ----------------------------------------------------------
const token = crypto.createHash('sha256').update(roomCode).digest().subarray(0, TOKEN_SIZE);
const socketA = dgram.createSocket('udp4');
const socketB = dgram.createSocket('udp4');
const receivedByB = [];
const receivedByA = [];
socketB.on('message', (message) => receivedByB.push(message));
socketA.on('message', (message) => receivedByA.push(message));
await new Promise((resolve) => socketA.bind(0, resolve));
await new Promise((resolve) => socketB.bind(0, resolve));

const sendVia = (socket, buffer) =>
  new Promise((resolve) => socket.send(buffer, MEDIA_PORT, '127.0.0.1', resolve));

// Media before the peer has registered must be dropped, not queued.
await sendVia(socketA, envelope(2, token, 0, Buffer.from('EARLY')));
await sleep(120);
check('media is dropped while the peer is unknown', () => {
  assert.equal(receivedByB.length, 0);
});

await sendVia(socketA, envelope(1, token, 0));
await sendVia(socketB, envelope(1, token, 1));
await sleep(120);

const payload = crypto.randomBytes(180);
await sendVia(socketA, envelope(2, token, 0, payload));
await sleep(180);

check('caller media reaches the callee byte-for-byte', () => {
  assert.equal(receivedByB.length, 1);
  assert.deepEqual(receivedByB[0], envelope(2, token, 0, payload));
});

const reply = crypto.randomBytes(64);
await sendVia(socketB, envelope(2, token, 1, reply));
await sleep(180);
check('callee media reaches the caller', () => {
  assert.equal(receivedByA.length, 1);
  assert.deepEqual(receivedByA[0], envelope(2, token, 1, reply));
});

check('keepalive frames are not forwarded as audio', () => {
  const before = receivedByB.length;
  socketA.send(envelope(1, token, 0), MEDIA_PORT, '127.0.0.1');
  assert.equal(receivedByB.length, before);
});

const otherToken = crypto.createHash('sha256').update('ZZZZZZ').digest().subarray(0, TOKEN_SIZE);
await sendVia(socketA, envelope(2, otherToken, 0, Buffer.from('WRONG ROOM')));
await sleep(150);
check('a different room does not leak into this one', () => {
  assert.equal(receivedByB.length, 1);
});

// --- hang-up --------------------------------------------------------------
callee.socket.close();
await sleep(250);
check('the surviving side is told the peer left', () => {
  assert.ok(caller.inbox.some((m) => m.type === 'peer-left'));
});

socketA.close();
socketB.close();
caller.socket.close();
server.kill('SIGTERM');
await sleep(200);

console.log(failures.length === 0
  ? '\nall relay checks passed'
  : `\n${failures.length} failed: ${failures.join(', ')}`);
process.exit(failures.length === 0 ? 0 : 1);
