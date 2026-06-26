const fs = require("fs");
const path = require("path");

const outDir = path.join(process.cwd(), "hardware", "arca-core-v0");
fs.mkdirSync(outDir, { recursive: true });

function v(x, y, z) {
  return [x, y, z];
}

function sub(a, b) {
  return [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
}

function cross(a, b) {
  return [
    a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2],
    a[0] * b[1] - a[1] * b[0],
  ];
}

function norm(a) {
  const length = Math.hypot(a[0], a[1], a[2]) || 1;
  return [a[0] / length, a[1] / length, a[2] / length];
}

function tri(a, b, c) {
  const n = norm(cross(sub(b, a), sub(c, a)));
  return { n, a, b, c };
}

function cuboid(cx, cy, cz, sx, sy, sz) {
  const x0 = cx - sx / 2;
  const x1 = cx + sx / 2;
  const y0 = cy - sy / 2;
  const y1 = cy + sy / 2;
  const z0 = cz - sz / 2;
  const z1 = cz + sz / 2;
  const p = {
    lbf: v(x0, y0, z0),
    rbf: v(x1, y0, z0),
    rbb: v(x1, y1, z0),
    lbb: v(x0, y1, z0),
    ltf: v(x0, y0, z1),
    rtf: v(x1, y0, z1),
    rtb: v(x1, y1, z1),
    ltb: v(x0, y1, z1),
  };
  return [
    tri(p.lbf, p.rbb, p.rbf), tri(p.lbf, p.lbb, p.rbb),
    tri(p.ltf, p.rtf, p.rtb), tri(p.ltf, p.rtb, p.ltb),
    tri(p.lbf, p.rtf, p.ltf), tri(p.lbf, p.rbf, p.rtf),
    tri(p.lbb, p.ltb, p.rtb), tri(p.lbb, p.rtb, p.rbb),
    tri(p.lbf, p.ltf, p.ltb), tri(p.lbf, p.ltb, p.lbb),
    tri(p.rbf, p.rbb, p.rtb), tri(p.rbf, p.rtb, p.rtf),
  ];
}

function cylinder(cx, cy, cz, radius, height, segments = 40) {
  const triangles = [];
  const z0 = cz - height / 2;
  const z1 = cz + height / 2;
  const topCenter = v(cx, cy, z1);
  const bottomCenter = v(cx, cy, z0);

  for (let i = 0; i < segments; i += 1) {
    const a0 = (Math.PI * 2 * i) / segments;
    const a1 = (Math.PI * 2 * (i + 1)) / segments;
    const p0 = v(cx + Math.cos(a0) * radius, cy + Math.sin(a0) * radius, z0);
    const p1 = v(cx + Math.cos(a1) * radius, cy + Math.sin(a1) * radius, z0);
    const p2 = v(cx + Math.cos(a1) * radius, cy + Math.sin(a1) * radius, z1);
    const p3 = v(cx + Math.cos(a0) * radius, cy + Math.sin(a0) * radius, z1);
    triangles.push(tri(p0, p2, p1), tri(p0, p3, p2));
    triangles.push(tri(topCenter, p3, p2));
    triangles.push(tri(bottomCenter, p1, p0));
  }
  return triangles;
}

function writeStl(name, triangles) {
  const body = triangles.map(({ n, a, b, c }) => [
    `  facet normal ${n[0]} ${n[1]} ${n[2]}`,
    "    outer loop",
    `      vertex ${a[0]} ${a[1]} ${a[2]}`,
    `      vertex ${b[0]} ${b[1]} ${b[2]}`,
    `      vertex ${c[0]} ${c[1]} ${c[2]}`,
    "    endloop",
    "  endfacet",
  ].join("\n")).join("\n");
  fs.writeFileSync(path.join(outDir, `${name}.stl`), `solid ${name}\n${body}\nendsolid ${name}\n`);
}

function tray(name, width, depth, height) {
  const wall = 2.4;
  const floor = 2.2;
  const backGap = Math.min(18, width * 0.38);
  const backSegment = (width - backGap) / 2;
  return [
    ...cuboid(0, 0, floor / 2, width, depth, floor),
    ...cuboid(-(width - wall) / 2, 0, height / 2, wall, depth, height),
    ...cuboid((width - wall) / 2, 0, height / 2, wall, depth, height),
    ...cuboid(0, -(depth - wall) / 2, height / 2, width, wall, height),
    ...cuboid(-(backGap + backSegment) / 2, (depth - wall) / 2, height / 2, backSegment, wall, height),
    ...cuboid((backGap + backSegment) / 2, (depth - wall) / 2, height / 2, backSegment, wall, height),
  ];
}

function makeFaceplate(width, depth) {
  const thickness = 3;
  const windowW = 24.5;
  const windowH = 13.5;
  const rim = 5.0;
  const yOffset = -2.2;
  const bars = [
    ...cuboid(0, -(depth - rim) / 2, thickness / 2, width, rim, thickness),
    ...cuboid(0, (depth - rim) / 2, thickness / 2, width, rim, thickness),
    ...cuboid(-(windowW + rim) / 2, yOffset, thickness / 2, rim, windowH, thickness),
    ...cuboid((windowW + rim) / 2, yOffset, thickness / 2, rim, windowH, thickness),
    ...cuboid(0, yOffset - (windowH + rim) / 2, thickness / 2, windowW + rim * 2, rim, thickness),
    ...cuboid(0, yOffset + (windowH + rim) / 2, thickness / 2, windowW + rim * 2, rim, thickness),
  ];
  const eyeDots = [
    ...cylinder(-7.2, yOffset, thickness + 0.45, 1.25, 0.9, 24),
    ...cylinder(7.2, yOffset, thickness + 0.45, 1.25, 0.9, 24),
  ];
  return [...bars, ...eyeDots];
}

function faceplate(name, width, depth) {
  writeStl(name, makeFaceplate(width, depth));
}

function monsterFaceplate(name, width, depth) {
  const thickness = 3;
  const base = makeFaceplate(width, depth);
  const hornZ = thickness / 2;
  const yTop = depth / 2 + 2.3;
  const yBottom = -depth / 2 - 2.2;
  const xSide = width / 2 + 2.1;
  const horns = [
    ...cylinder(-width * 0.28, yTop, hornZ, 4.8, thickness, 3),
    ...cylinder(width * 0.28, yTop, hornZ, 4.8, thickness, 3),
  ];
  const ears = [
    ...cylinder(-xSide, depth * 0.06, hornZ, 4.5, thickness, 18),
    ...cylinder(xSide, depth * 0.06, hornZ, 4.5, thickness, 18),
  ];
  const feet = [
    ...cuboid(-width * 0.22, yBottom, hornZ, 9, 5, thickness),
    ...cuboid(width * 0.22, yBottom, hornZ, 9, 5, thickness),
  ];
  const cheeks = [
    ...cylinder(-width * 0.3, -depth * 0.05, thickness + 0.42, 1.7, 0.85, 20),
    ...cylinder(width * 0.3, -depth * 0.05, thickness + 0.42, 1.7, 0.85, 20),
  ];
  writeStl(name, [...base, ...horns, ...ears, ...feet, ...cheeks]);
}

function oledFrame() {
  const width = 32;
  const depth = 31;
  const thickness = 2.4;
  const windowW = 24.5;
  const windowH = 13.5;
  const rim = 3.5;
  return [
    ...cuboid(0, -(depth - rim) / 2, thickness / 2, width, rim, thickness),
    ...cuboid(0, (depth - rim) / 2, thickness / 2, width, rim, thickness),
    ...cuboid(-(windowW + rim) / 2, 0, thickness / 2, rim, windowH, thickness),
    ...cuboid((windowW + rim) / 2, 0, thickness / 2, rim, windowH, thickness),
    ...cuboid(0, -(windowH + rim) / 2, thickness / 2, windowW + rim * 2, rim, thickness),
    ...cuboid(0, (windowH + rim) / 2, thickness / 2, windowW + rim * 2, rim, thickness),
  ];
}

writeStl("arca-core-v0-mini-tray-48x36x16", tray("mini", 48, 36, 16));
faceplate("arca-core-v0-mini-faceplate-48x36", 48, 36);
monsterFaceplate("arca-core-v0-mini-monster-faceplate-48x36", 48, 36);
writeStl("arca-core-v0-devkit-tray-70x45x18", tray("devkit", 70, 45, 18));
faceplate("arca-core-v0-devkit-faceplate-70x45", 70, 45);
monsterFaceplate("arca-core-v0-devkit-monster-faceplate-70x45", 70, 45);
writeStl("arca-oled-096-test-frame", oledFrame());

console.log(`Wrote ARCA Core v0 print files to ${outDir}`);
