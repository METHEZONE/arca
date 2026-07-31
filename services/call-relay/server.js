#!/usr/bin/env node
/**
 * ARCA call relay.
 *
 * Two jobs in one small process:
 *   1. WebSocket signaling — pairs two devices on a room code and forwards their
 *      Curve25519 public keys. Never sees the media key.
 *   2. UDP media relay — forwards opaque encrypted datagrams between the pair.
 *      Cannot decrypt them; it only reads the routing header.
 *
 * Why a relay instead of peer-to-peer: both ends are phones behind carrier NAT,
 * where hole punching fails often enough that you need a TURN fallback anyway —
 * and TURN *is* a relay. One predictable path beats two unpredictable ones.
 *
 * Deploy it in Seoul. The extra hop is the whole latency budget of this design,
 * so ~5ms to a Korean box is the difference between beating a normal call and
 * merely matching it. Oracle Cloud's always-free ARM instance in ap-seoul-1 is
 * enough: this process handles hundreds of concurrent calls on one core.
 */

import http from 'node:http';
import dgram from 'node:dgram';
import { WebSocketServer } from 'ws';

const SIGNALING_PORT = Number(process.env.SIGNALING_PORT ?? 8080);
const MEDIA_PORT = Number(process.env.MEDIA_PORT ?? 8081);

/** Envelope offsets — must match CallTransport.swift. */
const TYPE_REGISTER = 1;
const TYPE_MEDIA = 2;
const TOKEN_SIZE = 16;
const HEADER_SIZE = 1 + TOKEN_SIZE + 1;

/** A NAT binding is useless once it is this stale. */
const PEER_TTL_MS = 60_000;

// ---------------------------------------------------------------------------
// UDP media relay
// ---------------------------------------------------------------------------

/** token(hex) -> { 0: {address, port, lastSeen}, 1: {...} } */
const mediaRooms = new Map();
const media = dgram.createSocket({ type: 'udp4', recvBufferSize: 1 << 20 });

let forwarded = 0;
let dropped = 0;

media.on('message', (message, remote) => {
  if (message.length < HEADER_SIZE) return;

  const type = message[0];
  const token = message.subarray(1, 1 + TOKEN_SIZE).toString('hex');
  const side = message[1 + TOKEN_SIZE];
  if (side !== 0 && side !== 1) return;

  let room = mediaRooms.get(token);
  if (!room) {
    room = { 0: null, 1: null };
    mediaRooms.set(token, room);
  }

  // Every packet refreshes the sender's address. Mobile clients change IP when
  // they move between Wi-Fi and LTE mid-call, and this is what lets the call
  // survive that without any renegotiation.
  const existing = room[side];
  if (!existing || existing.address !== remote.address || existing.port !== remote.port) {
    console.log(`[media] ${token.slice(0, 8)} side ${side} -> ${remote.address}:${remote.port}`);
  }
  room[side] = { address: remote.address, port: remote.port, lastSeen: Date.now() };

  if (type === TYPE_REGISTER) return;
  if (type !== TYPE_MEDIA) return;

  const peer = room[side === 0 ? 1 : 0];
  if (!peer) {
    dropped += 1;
    return;
  }
  // Forwarded byte-for-byte. The payload past the header is ChaChaPoly sealed
  // with a key derived on the two devices, so this process is a dumb pipe.
  media.send(message, peer.port, peer.address, (error) => {
    if (error) console.warn(`[media] send failed: ${error.message}`);
  });
  forwarded += 1;
});

media.on('error', (error) => {
  console.error(`[media] socket error: ${error.message}`);
});

setInterval(() => {
  const now = Date.now();
  for (const [token, room] of mediaRooms) {
    for (const side of [0, 1]) {
      if (room[side] && now - room[side].lastSeen > PEER_TTL_MS) room[side] = null;
    }
    if (!room[0] && !room[1]) mediaRooms.delete(token);
  }
}, 15_000).unref();

setInterval(() => {
  if (forwarded === 0 && dropped === 0) return;
  console.log(`[media] forwarded=${forwarded} dropped=${dropped} rooms=${mediaRooms.size}`);
  forwarded = 0;
  dropped = 0;
}, 30_000).unref();

// ---------------------------------------------------------------------------
// WebSocket signaling
// ---------------------------------------------------------------------------

/** roomCode -> { caller: Client|null, callee: Client|null } */
const signalRooms = new Map();

const httpServer = http.createServer((request, response) => {
  if (request.url === '/health') {
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify({
      ok: true,
      signalRooms: signalRooms.size,
      mediaRooms: mediaRooms.size,
    }));
    return;
  }
  response.writeHead(404);
  response.end();
});

const wss = new WebSocketServer({ server: httpServer, path: '/call' });

function send(socket, payload) {
  if (socket && socket.readyState === socket.OPEN) {
    socket.send(JSON.stringify(payload));
  }
}

function peerOf(room, side) {
  return side === 'caller' ? room.callee : room.caller;
}

wss.on('connection', (socket) => {
  let room = null;
  let roomCode = null;
  let side = null;

  socket.isAlive = true;
  socket.on('pong', () => { socket.isAlive = true; });

  socket.on('message', (raw) => {
    let message;
    try {
      message = JSON.parse(raw.toString());
    } catch {
      return;
    }

    if (message.type === 'join') {
      const code = String(message.room ?? '').toUpperCase().trim();
      const wanted = message.side === 'callee' ? 'callee' : 'caller';
      if (!code || code.length > 32) {
        send(socket, { type: 'error', message: 'bad room code' });
        return;
      }

      let target = signalRooms.get(code);
      if (!target) {
        target = { caller: null, callee: null };
        signalRooms.set(code, target);
      }
      if (target[wanted]) {
        send(socket, { type: 'room-full' });
        return;
      }

      room = target;
      roomCode = code;
      side = wanted;
      room[side] = socket;
      socket.publicKey = message.publicKey ?? null;
      send(socket, { type: 'joined', side });
      console.log(`[signal] ${code} ${side} joined`);

      // Whoever arrives second completes the pair, so tell both at once.
      const peer = peerOf(room, side);
      if (peer) {
        send(socket, { type: 'peer-ready', publicKey: peer.publicKey });
        send(peer, { type: 'peer-ready', publicKey: socket.publicKey });
        console.log(`[signal] ${code} paired`);
      }
      return;
    }

    if (message.type === 'announce' && room && side) {
      socket.publicKey = message.publicKey ?? socket.publicKey;
      const peer = peerOf(room, side);
      if (peer) send(peer, { type: 'peer-ready', publicKey: socket.publicKey });
      return;
    }

    if (message.type === 'leave') {
      socket.close(1000, 'left');
    }
  });

  socket.on('close', () => {
    if (!room || !side) return;
    const peer = peerOf(room, side);
    room[side] = null;
    if (peer) send(peer, { type: 'peer-left' });
    if (!room.caller && !room.callee) signalRooms.delete(roomCode);
    console.log(`[signal] ${roomCode} ${side} left`);
  });
});

// A dead mobile socket looks alive to the server for minutes. Ping so the other
// side learns about a hang-up promptly instead of talking to nobody.
setInterval(() => {
  for (const socket of wss.clients) {
    if (!socket.isAlive) {
      socket.terminate();
      continue;
    }
    socket.isAlive = false;
    socket.ping();
  }
}, 15_000).unref();

media.bind(MEDIA_PORT, () => {
  console.log(`[media] udp listening on ${MEDIA_PORT}`);
});
httpServer.listen(SIGNALING_PORT, () => {
  console.log(`[signal] ws listening on ${SIGNALING_PORT}/call`);
});

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    console.log(`\n${signal} — shutting down`);
    media.close();
    httpServer.close();
    process.exit(0);
  });
}
