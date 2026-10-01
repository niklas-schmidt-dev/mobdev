/**
 * Geometry for the landing page's 3D story, as plain math without three.js: the folded m of the logo
 * as a swept band, and the point clouds the particles fly between (the m, three phones, a globe).
 * Units are world units; the camera sits about 9 units away.
 */

export type Vec3 = [number, number, number];

/** A small seeded generator, so every visit builds the same shapes. */
export function random(seed: number) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** `items[i]`, for indices the code has already bounded. */
export function item<T>(items: ArrayLike<T>, i: number): T {
  const value = items[i];
  if (value === undefined) throw new RangeError(`No item at ${i}`);
  return value;
}

const add = (a: Vec3, b: Vec3): Vec3 => [a[0] + b[0], a[1] + b[1], a[2] + b[2]];
const sub = (a: Vec3, b: Vec3): Vec3 => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
const scale = (a: Vec3, s: number): Vec3 => [a[0] * s, a[1] * s, a[2] * s];
const dot = (a: Vec3, b: Vec3) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
const cross = (a: Vec3, b: Vec3): Vec3 => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
const normalize = (a: Vec3): Vec3 => scale(a, 1 / (Math.hypot(a[0], a[1], a[2]) || 1));

/** Rotates `v` around the unit `axis` (Rodrigues). */
function rotate(v: Vec3, axis: Vec3, angle: number): Vec3 {
  const c = Math.cos(angle);
  const s = Math.sin(angle);
  return add(add(scale(v, c), scale(cross(axis, v), s)), scale(axis, dot(axis, v) * (1 - c)));
}

// The folded m: one band runs up the left leg, over the first arch and down the middle, folds back on
// itself at the bottom, and runs up again, over the second arch and down the right leg. The first half
// lies in front of the second, so the middle leg is the fold, as in the logo.
const band = {
  legX: 1.1,
  archY: 0.2,
  radius: 0.55,
  legBottom: -1.0,
  /** Half the distance between the front and the back layer. */
  layer: 0.26,
  halfWidth: 0.28,
  halfDepth: 0.17,
  corner: 0.13,
  /** Length of the rounded ends. */
  cap: 0.14,
};

function bandPath(step: number): Vec3[] {
  const { legX, archY, radius, legBottom, layer } = band;
  // The fold's outer edge lines up with the rounded ends of the outer legs.
  const turnY = legBottom - band.cap + layer + band.halfDepth;
  const points: Vec3[] = [];
  const line = (a: Vec3, b: Vec3) => {
    const n = Math.max(1, Math.round(Math.hypot(...sub(b, a)) / step));
    for (let i = 0; i < n; i++) points.push(add(a, scale(sub(b, a), i / n)));
  };
  const arch = (cx: number, z: number) => {
    const n = Math.round((Math.PI * radius) / step);
    for (let i = 0; i < n; i++) {
      const angle = Math.PI * (1 - i / n);
      points.push([cx + radius * Math.cos(angle), archY + radius * Math.sin(angle), z]);
    }
  };
  line([-legX, legBottom, layer], [-legX, archY, layer]);
  arch(-legX / 2, layer);
  line([0, archY, layer], [0, turnY, layer]);
  const n = Math.round((Math.PI * layer) / step);
  for (let i = 0; i < n; i++) {
    const angle = (Math.PI * i) / n;
    points.push([0, turnY - layer * Math.sin(angle), layer * Math.cos(angle)]);
  }
  line([0, turnY, -layer], [0, archY, -layer]);
  arch(legX / 2, -layer);
  line([legX, archY, -layer], [legX, legBottom, -layer]);
  points.push([legX, legBottom, -layer]);
  return points;
}

/** The band's cross-section: a rounded rectangle, counterclockwise, with outward normals. */
function crossSection(segments = 6) {
  const { halfWidth: a, halfDepth: c, corner: r } = band;
  const corners: [number, number][] = [
    [a - r, c - r],
    [-(a - r), c - r],
    [-(a - r), -(c - r)],
    [a - r, -(c - r)],
  ];
  const ring: { u: number; v: number; nu: number; nv: number }[] = [];
  corners.forEach(([cu, cv], k) => {
    for (let s = 0; s <= segments; s++) {
      const angle = (k + s / segments) * (Math.PI / 2);
      const nu = Math.cos(angle);
      const nv = Math.sin(angle);
      ring.push({ u: cu + r * nu, v: cv + r * nv, nu, nv });
    }
  });
  return ring;
}

type Frame = { p: Vec3; t: Vec3; n: Vec3; b: Vec3 };

/** Parallel-transport frames, so the band never twists: `n` spans its width and `b` its depth. */
function frames(path: Vec3[]): Frame[] {
  const result: Frame[] = [];
  let n: Vec3 = [1, 0, 0];
  let previous: Vec3 | null = null;
  path.forEach((p, i) => {
    const t = normalize(sub(item(path, Math.min(i + 1, path.length - 1)), item(path, Math.max(i - 1, 0))));
    if (previous) {
      const axis = cross(previous, t);
      const length = Math.hypot(...axis);
      if (length > 1e-6) n = normalize(rotate(n, scale(axis, 1 / length), Math.acos(Math.min(1, Math.max(-1, dot(previous, t))))));
    }
    previous = t;
    result.push({ p, t, n, b: cross(t, n) });
  });
  return result;
}

export type BandGeometry = {
  positions: Float32Array;
  normals: Float32Array;
  /** 0 at the start of the band, 1 at its end, for coloring along it. */
  along: Float32Array;
  indices: Uint32Array;
};

let cachedFrames: Frame[] | null = null;
const bandFrames = () => (cachedFrames ??= frames(bandPath(0.012)));

/** The folded m as an indexed triangle mesh with rounded ends. */
export function bandGeometry(): BandGeometry {
  const path = bandFrames();
  const section = crossSection();
  const capRings = 8;
  const rings: { center: Vec3; t: Vec3; n: Vec3; b: Vec3; size: number; bend: number; along: number }[] = [];
  const first = item(path, 0);
  const last = item(path, path.length - 1);
  // bend: how far the normals tilt along the path at the rounded ends, as sin of the dome angle.
  for (let k = capRings; k >= 1; k--) {
    const angle = (k / capRings) * (Math.PI / 2);
    rings.push({ ...first, center: sub(first.p, scale(first.t, band.cap * Math.sin(angle))), size: Math.cos(angle), bend: -Math.sin(angle), along: 0 });
  }
  path.forEach((frame, i) => rings.push({ ...frame, center: frame.p, size: 1, bend: 0, along: i / (path.length - 1) }));
  for (let k = 1; k <= capRings; k++) {
    const angle = (k / capRings) * (Math.PI / 2);
    rings.push({ ...last, center: add(last.p, scale(last.t, band.cap * Math.sin(angle))), size: Math.cos(angle), bend: Math.sin(angle), along: 1 });
  }

  const m = section.length;
  const positions = new Float32Array(rings.length * m * 3);
  const normals = new Float32Array(rings.length * m * 3);
  const along = new Float32Array(rings.length * m);
  rings.forEach((ring, i) => {
    const straight = Math.sqrt(1 - ring.bend * ring.bend);
    section.forEach((s, j) => {
      const offset = add(scale(ring.n, s.u * ring.size), scale(ring.b, s.v * ring.size));
      const normal = normalize(add(scale(add(scale(ring.n, s.nu), scale(ring.b, s.nv)), straight), scale(ring.t, ring.bend)));
      positions.set(add(ring.center, offset), (i * m + j) * 3);
      normals.set(normal, (i * m + j) * 3);
      along[i * m + j] = ring.along;
    });
  });

  const indices = new Uint32Array((rings.length - 1) * m * 6);
  let o = 0;
  for (let i = 0; i < rings.length - 1; i++) {
    for (let j = 0; j < m; j++) {
      const a = i * m + j;
      const b = i * m + ((j + 1) % m);
      const c = a + m;
      const d = b + m;
      indices.set([a, b, c, b, d, c], o);
      o += 6;
    }
  }
  return { positions, normals, along, indices };
}

/**
 * Particles on and around the band's surface. Returns xyzw per point, w being its brightness.
 */
function bandPoints(count: number, rand: () => number) {
  const path = bandFrames();
  const section = crossSection();
  const lengths = section.map((s, j) => {
    const next = item(section, (j + 1) % section.length);
    return Math.hypot(next.u - s.u, next.v - s.v);
  });
  const perimeter = lengths.reduce((sum, l) => sum + l, 0);
  const out = new Float32Array(count * 4);
  for (let i = 0; i < count; i++) {
    const frame = item(path, Math.floor(rand() * path.length));
    let target = rand() * perimeter;
    let j = 0;
    while (target > item(lengths, j) && j < lengths.length - 1) target -= item(lengths, j++);
    const f = target / item(lengths, j);
    const s = item(section, j);
    const next = item(section, (j + 1) % section.length);
    const u = s.u + (next.u - s.u) * f;
    const v = s.v + (next.v - s.v) * f;
    const normal = normalize(add(scale(frame.n, s.nu + (next.nu - s.nu) * f), scale(frame.b, s.nv + (next.nv - s.nv) * f)));
    // Most points hug the surface; a few drift further out as a halo.
    const halo = rand() < 0.06;
    const lift = halo ? 0.04 + rand() * rand() * 0.4 : 0.006 + rand() * rand() * 0.025;
    const p = add(add(frame.p, add(scale(frame.n, u), scale(frame.b, v))), scale(normal, lift));
    out.set([...p, halo ? 0.4 : 0.9], i * 4);
  }
  return out;
}

// Phones

export type PhoneKind = "iphone" | "simulator" | "android";
export type Placement = { x: number; y: number; z: number; turn: number; size: number };

const phone = { width: 1.2, height: 2.6, depth: 0.055 };

type Shape =
  | { kind: "rect"; x: number; y: number; w: number; h: number; r: number; light: number }
  | { kind: "circle"; x: number; y: number; r: number; light: number };

const rect = (x: number, y: number, w: number, h: number, r: number, light: number): Shape => ({ kind: "rect", x, y, w, h, r, light });
const circle = (x: number, y: number, r: number, light: number): Shape => ({ kind: "circle", x, y, r, light });

/** Seven-segment digits, for the clock on the Android home screen. */
function digit(value: number, x: number, y: number, w: number, h: number): Shape[] {
  const on = item(["abcdef", "bc", "abdeg", "abcdg", "bcfg", "acdfg", "acdefg", "abc", "abcdefg", "abcdfg"], value);
  const t = w * 0.24;
  const segments: Record<string, Shape> = {
    a: rect(x, y + h / 2 - t / 2, w, t, t / 2, 1),
    g: rect(x, y, w, t, t / 2, 1),
    d: rect(x, y - h / 2 + t / 2, w, t, t / 2, 1),
    f: rect(x - w / 2 + t / 2, y + h / 4, t, h / 2, t / 2, 1),
    b: rect(x + w / 2 - t / 2, y + h / 4, t, h / 2, t / 2, 1),
    e: rect(x - w / 2 + t / 2, y - h / 4, t, h / 2, t / 2, 1),
    c: rect(x + w / 2 - t / 2, y - h / 4, t, h / 2, t / 2, 1),
  };
  return [...on].flatMap((key) => segments[key] ?? []);
}

/** What each phone's screen shows: an iPhone home screen, an app on the simulator, Android's home screen. */
function screen(kind: PhoneKind, rand: () => number): Shape[] {
  const columns = [-0.39, -0.13, 0.13, 0.39];
  if (kind === "iphone") {
    const shapes = [rect(0, 1.12, 0.34, 0.1, 0.05, 1), rect(-0.37, 1.12, 0.14, 0.04, 0.02, 0.8), rect(0.38, 1.12, 0.12, 0.05, 0.02, 0.8)];
    for (let row = 0; row < 5; row++) for (const x of columns) shapes.push(rect(x, 0.82 - row * 0.3, 0.2, 0.2, 0.055, 0.85));
    shapes.push(rect(0, -0.98, 0.98, 0.3, 0.1, 0.3), circle(-0.03, -0.72, 0.012, 1), circle(0.03, -0.72, 0.012, 0.6));
    for (const x of columns) shapes.push(rect(x, -0.98, 0.2, 0.2, 0.055, 0.95));
    return shapes;
  }
  if (kind === "simulator") {
    const shapes = [rect(0, 1.12, 0.34, 0.1, 0.05, 1), rect(-0.25, 0.86, 0.46, 0.1, 0.03, 1), rect(0, 0.66, 0.94, 0.12, 0.06, 0.35)];
    for (let row = 0; row < 7; row++) {
      const y = 0.42 - row * 0.235;
      const title = 0.35 + rand() * 0.35;
      const detail = 0.25 + rand() * 0.3;
      shapes.push(rect(-0.47 + title / 2, y, title, 0.045, 0.02, 0.9), rect(-0.47 + detail / 2, y - 0.075, detail, 0.03, 0.015, 0.5), rect(0, y - 0.135, 0.94, 0.006, 0.003, 0.3));
    }
    shapes.push(rect(0.37, -1.08, 0.1, 0.1, 0.03, 1));
    return shapes;
  }
  const shapes = [circle(0, 1.13, 0.035, 1), rect(0, 0.42, 0.4, 0.035, 0.017, 0.6), rect(0, -0.98, 0.94, 0.16, 0.08, 0.45), circle(-0.36, -0.98, 0.04, 1), circle(0.36, -0.98, 0.025, 0.9), rect(0, -1.17, 0.3, 0.018, 0.009, 0.8)];
  [1, 2, 3, 0].forEach((value, i) => shapes.push(...digit(value, -0.36 + i * 0.22 + (i > 1 ? 0.06 : 0), 0.72, 0.13, 0.32)));
  shapes.push(circle(0, 0.78, 0.018, 1), circle(0, 0.66, 0.018, 1));
  for (const y of [-0.22, -0.54]) for (const x of columns) shapes.push(circle(x, y, 0.1, 0.85));
  return shapes;
}

function area(shape: Shape) {
  return shape.kind === "circle" ? Math.PI * shape.r * shape.r : shape.w * shape.h;
}

function insideRect(x: number, y: number, w: number, h: number, r: number) {
  const qx = Math.abs(x) - (w / 2 - r);
  const qy = Math.abs(y) - (h / 2 - r);
  return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) <= r;
}

function pointIn(shape: Shape, rand: () => number): [number, number] {
  if (shape.kind === "circle") {
    const angle = rand() * Math.PI * 2;
    const r = shape.r * Math.sqrt(rand());
    return [shape.x + r * Math.cos(angle), shape.y + r * Math.sin(angle)];
  }
  for (;;) {
    const x = (rand() - 0.5) * shape.w;
    const y = (rand() - 0.5) * shape.h;
    if (insideRect(x, y, shape.w, shape.h, shape.r)) return [shape.x + x, shape.y + y];
  }
}

/** A point on a rounded rectangle's outline, uniformly by length. */
function pointOnOutline(w: number, h: number, r: number, rand: () => number): [number, number] {
  const straightW = w - 2 * r;
  const straightH = h - 2 * r;
  const arc = (Math.PI / 2) * r;
  let t = rand() * (2 * straightW + 2 * straightH + 4 * arc);
  const sides: [number, (t: number) => [number, number]][] = [
    [straightW, (t) => [-straightW / 2 + t, h / 2]],
    [arc, (t) => [straightW / 2 + r * Math.sin(t / r), straightH / 2 + r * Math.cos(t / r)]],
    [straightH, (t) => [w / 2, straightH / 2 - t]],
    [arc, (t) => [straightW / 2 + r * Math.cos(t / r), -straightH / 2 - r * Math.sin(t / r)]],
    [straightW, (t) => [straightW / 2 - t, -h / 2]],
    [arc, (t) => [-straightW / 2 - r * Math.sin(t / r), -straightH / 2 - r * Math.cos(t / r)]],
    [straightH, (t) => [-w / 2, -straightH / 2 + t]],
    [arc, (t) => [-straightW / 2 - r * Math.cos(t / r), straightH / 2 + r * Math.sin(t / r)]],
  ];
  for (const [length, at] of sides) {
    if (t <= length) return at(t);
    t -= length;
  }
  return [0, h / 2];
}

/** Moves a point from a phone's own coordinates into the scene. */
export function place(p: Vec3, at: Placement): Vec3 {
  const x = p[0] * at.size;
  const z = p[2] * at.size;
  const c = Math.cos(at.turn);
  const s = Math.sin(at.turn);
  return [at.x + x * c + z * s, at.y + p[1] * at.size, at.z - x * s + z * c];
}

/** A point on a phone's screen, where the story shows an agent's tap. */
export function screenPoint(at: Placement, rand: () => number): Vec3 {
  return place([(rand() - 0.5) * 0.8, (rand() - 0.5) * 1.8, phone.depth], at);
}

function phonePoints(kind: PhoneKind, count: number, at: Placement, rand: () => number) {
  const corner = kind === "android" ? 0.15 : 0.2;
  const shapes = screen(kind, rand);
  const cumulative: number[] = [];
  let total = 0;
  for (const shape of shapes) cumulative.push((total += area(shape)));
  const out = new Float32Array(count * 4);
  for (let i = 0; i < count; i++) {
    const roll = rand();
    let p: Vec3;
    let light: number;
    if (roll < 0.3) {
      // The frame, denser at its front and back edges.
      const [x, y] = pointOnOutline(phone.width, phone.height, corner, rand);
      const inset = 1 - rand() * 0.012;
      const edge = rand() < 0.7 ? Math.sign(rand() - 0.5) : rand() * 2 - 1;
      p = [x * inset, y * inset, edge * phone.depth];
      light = 1;
    } else if (roll < 0.38) {
      // The glass, faint.
      const [x, y] = pointIn(rect(0, 0, phone.width - 0.12, phone.height - 0.12, corner - 0.05, 0), rand);
      p = [x, y, phone.depth];
      light = 0.18;
    } else {
      const pick = rand() * total;
      const shape = item(shapes, Math.max(0, cumulative.findIndex((c) => c >= pick)));
      const [x, y] = pointIn(shape, rand);
      p = [x, y, phone.depth + 0.004];
      light = shape.light;
    }
    out.set([...place(p, at), light], i * 4);
  }
  return out;
}

export const phoneKinds: PhoneKind[] = ["iphone", "simulator", "android"];

/** Three phones side by side, turned towards the middle; closer together on narrow screens. */
export function phonePlacements(narrow: boolean): Placement[] {
  return narrow
    ? [
        { x: -1.45, y: 0, z: -0.1, turn: 0.14, size: 1 },
        { x: 0, y: 0, z: 0.1, turn: 0, size: 1 },
        { x: 1.45, y: 0, z: -0.1, turn: -0.14, size: 1 },
      ]
    : [
        { x: -2.25, y: 0, z: -0.15, turn: 0.2, size: 1 },
        { x: 0, y: 0, z: 0.1, turn: 0, size: 1 },
        { x: 2.25, y: 0, z: -0.15, turn: -0.2, size: 1 },
      ];
}

// Globe

const globeRadius = 1.55;

/** Unit vector for a latitude and longitude, in radians. */
function onSphere(lat: number, lon: number): Vec3 {
  return [Math.cos(lat) * Math.sin(lon), Math.sin(lat), Math.cos(lat) * Math.cos(lon)];
}

function slerp(a: Vec3, b: Vec3, t: number): Vec3 {
  const angle = Math.acos(Math.min(1, Math.max(-1, dot(a, b))));
  const s = Math.sin(angle) || 1;
  return add(scale(a, Math.sin((1 - t) * angle) / s), scale(b, Math.sin(t * angle) / s));
}

/**
 * A dotted globe with Macs on it and arcs between them, for remote access. Returns the points and,
 * per point, how far along its arc it sits (or -1), which the shader turns into travelling light.
 */
function globePoints(count: number, rand: () => number) {
  const out = new Float32Array(count * 4);
  const arcAt = new Float32Array(count).fill(-1);
  const nodes: Vec3[] = (
    [
    [0.9, -1.3],
    [0.72, 0.2],
    [0.62, 2.4],
    [-0.4, 0.5],
    [0.25, -0.2],
    [-0.6, 2.2],
    [0.35, 1.3],
  ] as const).map(([lat, lon]) => onSphere(lat, lon));
  const arcs: [number, number][] = [
    [0, 1],
    [1, 2],
    [1, 3],
    [4, 6],
    [6, 5],
    [0, 4],
    [2, 6],
  ];
  const golden = Math.PI * (3 - Math.sqrt(5));
  const dots = Math.floor(count * 0.36);
  for (let i = 0; i < count; i++) {
    const roll = i / count;
    let p: Vec3;
    let light = 0.5;
    if (i < dots) {
      // An even dotted sphere (Fibonacci lattice).
      const y = 1 - (2 * (i + 0.5)) / dots;
      const r = Math.sqrt(1 - y * y);
      // Jittered, so the lattice does not shimmer into moiré.
      const jitter: Vec3 = [rand() - 0.5, rand() - 0.5, rand() - 0.5];
      p = scale(normalize(add([Math.cos(golden * i) * r, y, Math.sin(golden * i) * r], scale(jitter, 0.03))), globeRadius);
      light = 0.3 + 0.12 * rand();
    } else if (roll < 0.5) {
      // Lines of latitude and longitude.
      const angle = rand() * Math.PI * 2;
      p = rand() < 0.5
        ? scale(onSphere(((Math.floor(rand() * 5) - 2) * Math.PI) / 6, angle), globeRadius * 1.004)
        : scale(onSphere(angle, (Math.floor(rand() * 6) * Math.PI) / 6), globeRadius * 1.004);
      light = 0.26;
    } else if (roll < 0.58) {
      // Glowing Macs.
      const node = item(nodes, Math.floor(rand() * nodes.length));
      const spread = rand() * 0.07;
      p = add(scale(node, globeRadius * 1.01), scale(normalize([rand() - 0.5, rand() - 0.5, rand() - 0.5]), spread));
      light = 1;
    } else {
      const [from, to] = item(arcs, Math.floor(rand() * arcs.length));
      const t = rand();
      const lift = 1.01 + 0.3 * Math.sin(Math.PI * t);
      p = scale(slerp(item(nodes, from), item(nodes, to), t), globeRadius * lift);
      arcAt[i] = t;
      light = 0.5;
    }
    out.set([...p, light], i * 4);
  }
  return { points: out, arcAt };
}

/**
 * Everything the particles need, in one order: particle i sits at m[i], flies to phones[i], then to
 * globe[i]. All three clouds are sorted left to right before they are paired, so neighbours stay
 * neighbours and the left leg of the m becomes the left phone.
 */
export function particleTargets(count: number, narrow: boolean) {
  const rand = random(7);
  const m = sortByX(bandPoints(count, rand));
  const { phones, phoneOf } = phoneTargets(count, narrow);
  const globe = globePoints(count, rand);
  const globeOrder = order(globe.points);
  const globeSorted = new Float32Array(count * 4);
  const meta = new Float32Array(count * 4);
  globeOrder.forEach((from, to) => {
    globeSorted.set(globe.points.subarray(from * 4, from * 4 + 4), to * 4);
    meta.set([rand(), item(phoneOf, to), item(globe.arcAt, from), 0.6 + rand() * 0.8], to * 4);
  });
  return { m, phones, globe: globeSorted, meta };
}

/** The phones' points, sorted left to right, and which phone each belongs to. */
export function phoneTargets(count: number, narrow: boolean) {
  const rand = random(11);
  const placements = phonePlacements(narrow);
  const per = Math.floor(count / 3);
  const points = new Float32Array(count * 4);
  const owner = new Float32Array(count);
  phoneKinds.forEach((kind, k) => {
    const n = k === 2 ? count - 2 * per : per;
    points.set(phonePoints(kind, n, item(placements, k), rand), k * per * 4);
    owner.fill(k, k * per, k * per + n);
  });
  const sorted = order(points);
  const phones = new Float32Array(count * 4);
  const phoneOf = new Float32Array(count);
  sorted.forEach((from, to) => {
    phones.set(points.subarray(from * 4, from * 4 + 4), to * 4);
    phoneOf[to] = item(owner, from);
  });
  return { phones, phoneOf };
}

function order(points: Float32Array) {
  const indices = Array.from({ length: points.length / 4 }, (_, i) => i);
  const x = (i: number) => item(points, i * 4);
  const y = (i: number) => item(points, i * 4 + 1);
  return indices.sort((a, b) => x(a) - x(b) || y(a) - y(b));
}

function sortByX(points: Float32Array) {
  const sorted = new Float32Array(points.length);
  order(points).forEach((from, to) => sorted.set(points.subarray(from * 4, from * 4 + 4), to * 4));
  return sorted;
}
