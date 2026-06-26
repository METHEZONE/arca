const fs = require("fs");
const path = require("path");

const W = 128;
const H = 64;
const FRAME_BYTES = (W * H) / 8;
const outDir = path.join(process.cwd(), "hardware", "arca-qbit-facepack");
fs.mkdirSync(outDir, { recursive: true });

function makeFrame() {
  return new Uint8Array(W * H);
}

function set(frame, x, y, value = 1) {
  const ix = Math.round(x);
  const iy = Math.round(y);
  if (ix >= 0 && ix < W && iy >= 0 && iy < H) frame[iy * W + ix] = value;
}

function line(frame, x0, y0, x1, y1, value = 1) {
  const steps = Math.max(Math.abs(x1 - x0), Math.abs(y1 - y0), 1);
  for (let i = 0; i <= steps; i += 1) {
    const t = i / steps;
    set(frame, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, value);
  }
}

function rect(frame, x, y, w, h, value = 1, fill = true) {
  for (let yy = 0; yy < h; yy += 1) {
    for (let xx = 0; xx < w; xx += 1) {
      if (fill || yy === 0 || yy === h - 1 || xx === 0 || xx === w - 1) set(frame, x + xx, y + yy, value);
    }
  }
}

function ellipse(frame, cx, cy, rx, ry, value = 1, fill = true) {
  for (let y = Math.floor(cy - ry); y <= Math.ceil(cy + ry); y += 1) {
    for (let x = Math.floor(cx - rx); x <= Math.ceil(cx + rx); x += 1) {
      const d = ((x - cx) ** 2) / (rx ** 2) + ((y - cy) ** 2) / (ry ** 2);
      if (fill ? d <= 1 : d > 0.72 && d <= 1.1) set(frame, x, y, value);
    }
  }
}

function arc(frame, cx, cy, rx, ry, start, end, value = 1) {
  for (let a = start; a <= end; a += 0.025) {
    set(frame, cx + Math.cos(a) * rx, cy + Math.sin(a) * ry, value);
  }
}

function sparkle(frame, cx, cy, r = 4) {
  line(frame, cx - r, cy, cx + r, cy);
  line(frame, cx, cy - r, cx, cy + r);
  set(frame, cx - 2, cy - 2);
  set(frame, cx + 2, cy + 2);
}

function tinyText(frame, x, y, text) {
  const font = {
    A: ["0110", "1001", "1111", "1001", "1001"],
    C: ["0111", "1000", "1000", "1000", "0111"],
    R: ["1110", "1001", "1110", "1010", "1001"],
    U: ["1001", "1001", "1001", "1001", "0110"],
    P: ["1110", "1001", "1110", "1000", "1000"],
    L: ["1000", "1000", "1000", "1000", "1111"],
    O: ["0110", "1001", "1001", "1001", "0110"],
    D: ["1110", "1001", "1001", "1001", "1110"],
    I: ["111", "010", "010", "010", "111"],
    N: ["1001", "1101", "1011", "1001", "1001"],
    G: ["0111", "1000", "1011", "1001", "0111"],
    ".": ["0", "0", "0", "0", "1"],
  };
  let cursor = x;
  for (const ch of text) {
    const glyph = font[ch];
    if (!glyph) {
      cursor += 4;
      continue;
    }
    glyph.forEach((row, yy) => {
      [...row].forEach((bit, xx) => {
        if (bit === "1") set(frame, cursor + xx, y + yy);
      });
    });
    cursor += glyph[0].length + 1;
  }
}

function cuteEyes(frame, opts = {}) {
  const {
    lx = 42,
    rx = 86,
    y = 30,
    eyeW = 18,
    eyeH = 13,
    pupilX = 0,
    pupilY = 0,
    closed = false,
    smile = true,
    blush = false,
    horns = false,
  } = opts;

  if (horns) {
    line(frame, 24, 9, 32, 2);
    line(frame, 32, 2, 39, 11);
    line(frame, 89, 11, 96, 2);
    line(frame, 96, 2, 104, 9);
  }

  if (closed) {
    arc(frame, lx, y, eyeW / 2, 4, 0.05, Math.PI - 0.05);
    arc(frame, rx, y, eyeW / 2, 4, 0.05, Math.PI - 0.05);
  } else {
    ellipse(frame, lx, y, eyeW / 2, eyeH / 2, 1, false);
    ellipse(frame, rx, y, eyeW / 2, eyeH / 2, 1, false);
    ellipse(frame, lx + pupilX, y + pupilY, 3, 4);
    ellipse(frame, rx + pupilX, y + pupilY, 3, 4);
    set(frame, lx + pupilX - 1, y + pupilY - 2, 0);
    set(frame, rx + pupilX - 1, y + pupilY - 2, 0);
  }

  if (smile) arc(frame, 64, 45, 13, 6, 0.15, Math.PI - 0.15);
  if (blush) {
    line(frame, 21, 41, 30, 38);
    line(frame, 99, 38, 108, 41);
  }
}

function packFrame(frame) {
  const bytes = new Uint8Array(FRAME_BYTES);
  for (let y = 0; y < H; y += 1) {
    for (let x = 0; x < W; x += 1) {
      if (frame[y * W + x]) {
        const index = y * Math.ceil(W / 8) + Math.floor(x / 8);
        bytes[index] |= 1 << (7 - (x % 8));
      }
    }
  }
  return bytes;
}

function writeQgif(name, frames, delays) {
  const header = Buffer.alloc(5 + frames.length * 2);
  header.writeUInt8(frames.length, 0);
  header.writeUInt16LE(W, 1);
  header.writeUInt16LE(H, 3);
  delays.forEach((delay, i) => header.writeUInt16LE(delay, 5 + i * 2));
  const payload = Buffer.concat(frames.map((frame) => Buffer.from(packFrame(frame))));
  fs.writeFileSync(path.join(outDir, `${name}.qgif`), Buffer.concat([header, payload]));
}

function writeSvgPreview(packs) {
  const scale = 3;
  const cols = 3;
  const cellW = W * scale + 24;
  const cellH = H * scale + 42;
  const rows = Math.ceil(packs.length / cols);
  const parts = [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${cols * cellW}" height="${rows * cellH}" viewBox="0 0 ${cols * cellW} ${rows * cellH}">`,
    `<rect width="100%" height="100%" fill="#080808"/>`,
  ];
  packs.forEach((pack, i) => {
    const col = i % cols;
    const row = Math.floor(i / cols);
    const ox = col * cellW + 12;
    const oy = row * cellH + 26;
    parts.push(`<text x="${ox}" y="${oy - 8}" fill="#f5efe5" font-family="monospace" font-size="13">${pack.name}</text>`);
    parts.push(`<rect x="${ox}" y="${oy}" width="${W * scale}" height="${H * scale}" rx="8" fill="#120f0d" stroke="#4b3327"/>`);
    const frame = pack.frames[Math.min(1, pack.frames.length - 1)];
    for (let y = 0; y < H; y += 1) {
      for (let x = 0; x < W; x += 1) {
        if (frame[y * W + x]) parts.push(`<rect x="${ox + x * scale}" y="${oy + y * scale}" width="${scale}" height="${scale}" fill="#ffb26b"/>`);
      }
    }
  });
  parts.push("</svg>");
  fs.writeFileSync(path.join(outDir, "arca-qbit-facepack-preview.svg"), parts.join("\n"));
}

function idleBlink() {
  return [0, 1, 2, 1, 0].map((step) => {
    const f = makeFrame();
    cuteEyes(f, { eyeH: step === 2 ? 2 : 13 - step * 4, smile: true, blush: true });
    sparkle(f, 18, 13, 3);
    tinyText(f, 52, 55, "ARCA");
    return f;
  });
}

function listening() {
  return [-4, -2, 0, 2, 4, 2, 0, -2].map((pupilX, i) => {
    const f = makeFrame();
    cuteEyes(f, { pupilX, eyeH: 15, smile: i % 3 !== 0 });
    arc(f, 15, 31, 8 + i, 18, -1.1, 1.1);
    arc(f, 113, 31, 8 + i, 18, Math.PI - 1.1, Math.PI + 1.1);
    return f;
  });
}

function thinking() {
  return [0, 1, 2, 3, 2, 1].map((step) => {
    const f = makeFrame();
    cuteEyes(f, { pupilX: 2, pupilY: -2, smile: false });
    arc(f, 64, 47, 10, 4, Math.PI + 0.1, Math.PI * 2 - 0.1);
    for (let i = 0; i < 3; i += 1) ellipse(f, 96 + i * 6, 13 - ((step + i) % 4), 2 + i, 2 + i, 1, false);
    return f;
  });
}

function uploading() {
  return [0, 1, 2, 3, 4, 5].map((step) => {
    const f = makeFrame();
    cuteEyes(f, { closed: step % 2 === 1, smile: true });
    rect(f, 37, 51, 54, 5, 1, false);
    rect(f, 39, 53, 8 + step * 8, 1);
    line(f, 64, 13, 64, 4);
    line(f, 64, 4, 58, 10);
    line(f, 64, 4, 70, 10);
    tinyText(f, 47, 58, "UPLOAD");
    return f;
  });
}

function sleepy() {
  return [0, 1, 2, 3, 2, 1].map((step) => {
    const f = makeFrame();
    cuteEyes(f, { closed: true, smile: true });
    tinyText(f, 93, 8 + step, "Z");
    tinyText(f, 105, 4 + step * 2, "Z");
    return f;
  });
}

function excitedMonster() {
  return [0, 1, 0, 2].map((step) => {
    const f = makeFrame();
    cuteEyes(f, { eyeW: 20 + step * 2, eyeH: 16 + step, pupilY: -1, smile: true, blush: true, horns: true });
    sparkle(f, 16, 20, 4 + step);
    sparkle(f, 112, 20, 4 + step);
    return f;
  });
}

function shy() {
  return [-2, 0, 2, 0].map((pupilX) => {
    const f = makeFrame();
    cuteEyes(f, { pupilX, eyeH: 9, smile: true, blush: true });
    line(f, 20, 43, 33, 38);
    line(f, 95, 38, 108, 43);
    return f;
  });
}

function alertRecord() {
  return [0, 1, 0, 1].map((step) => {
    const f = makeFrame();
    cuteEyes(f, { eyeW: 16, eyeH: 18, smile: false });
    ellipse(f, 64, 47, step ? 5 : 3, step ? 5 : 3);
    tinyText(f, 51, 55, "REC");
    return f;
  });
}

const packs = [
  { name: "arca_idle_blink", frames: idleBlink(), delays: [260, 120, 90, 120, 360] },
  { name: "arca_listening_waves", frames: listening(), delays: Array(8).fill(120) },
  { name: "arca_thinking_bubbles", frames: thinking(), delays: Array(6).fill(180) },
  { name: "arca_uploading_cloud", frames: uploading(), delays: Array(6).fill(150) },
  { name: "arca_sleepy_mochi", frames: sleepy(), delays: Array(6).fill(220) },
  { name: "arca_excited_monster", frames: excitedMonster(), delays: Array(4).fill(130) },
  { name: "arca_shy_blush", frames: shy(), delays: Array(4).fill(180) },
  { name: "arca_recording_pulse", frames: alertRecord(), delays: Array(4).fill(160) },
];

for (const pack of packs) writeQgif(pack.name, pack.frames, pack.delays);
writeSvgPreview(packs);

const manifest = {
  format: "qbit-qgif",
  target: "SSD1306 128x64 0.96 inch OLED",
  generatedAt: new Date().toISOString(),
  sourcePolicy: "Original ARCA pixel expressions inspired by desktop-pet interaction patterns; do not copy DASAI/Mochi commercial art.",
  packs: packs.map((pack) => ({
    file: `${pack.name}.qgif`,
    frames: pack.frames.length,
    width: W,
    height: H,
    delaysMs: pack.delays,
  })),
};
fs.writeFileSync(path.join(outDir, "manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);

console.log(`Wrote ${packs.length} ARCA QBIT face animations to ${outDir}`);
