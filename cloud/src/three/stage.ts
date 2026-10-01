/**
 * The landing page's 3D stage: the folded m as a solid, lit object, and a cloud of particles that
 * leaves it and becomes three phones, then a globe. On WebGPU the particles run in a compute
 * shader, so their flight and the pointer's push cost the main thread nothing; three.js's WebGL 2
 * fallback moves them in the vertex shader instead. Loaded on demand; the page stays readable without it.
 */
import * as THREE from "three/webgpu";
import {
  Fn,
  PI,
  attribute,
  clamp,
  cos,
  dot,
  exp,
  float,
  fract,
  hash,
  instanceIndex,
  instancedArray,
  length,
  max,
  mix,
  mx_noise_float,
  mx_noise_vec3,
  normalLocal,
  positionLocal,
  shapeCircle,
  sin,
  smoothstep,
  step,
  uniform,
  varyingProperty,
  vec3,
} from "three/tsl";
import { RoomEnvironment } from "three/addons/environments/RoomEnvironment.js";
import { bandGeometry, item, particleTargets, phonePlacements, phoneTargets, place, random, screenPoint, type Vec3 } from "./shapes";

/** Where the story is, each 0 to 1. The page derives these from the scroll position. */
export type StoryState = {
  /** The solid m dissolves into its particles. */
  dissolve: number;
  /** The particles fly from the m to the phones. */
  toPhones: number;
  /** Taps ripple over the phones' screens. */
  agent: number;
  /** The particles fly from the phones to the globe. */
  toGlobe: number;
};

/**
 * Where each state's object may go, as [top, bottom] in CSS pixels from the top of the stage:
 * the space the page's text leaves free. The agent chapter keeps the phones above its activity card.
 */
export type StageLayout = { m: Region; devices: Region; agent: Region; globe: Region };
type Region = readonly [number, number];

export type StageOptions = {
  canvas: HTMLCanvasElement;
  dark: boolean;
  reducedMotion: boolean;
  /** Called after each rendered frame, to move page elements along with the scene. */
  onFrame?: (stage: Stage) => void;
  /** Called when an agent's tap lands on phone 0, 1 or 2, at a point in CSS pixels. */
  onTap?: (phone: number, at: { x: number; y: number }) => void;
};

export type Stage = {
  backend: "webgpu" | "webgl";
  setState(state: StoryState): void;
  /** The pointer in normalized device coordinates, or null when it left. */
  setPointer(pointer: { x: number; y: number } | null): void;
  setDark(dark: boolean): void;
  resize(width: number, height: number): void;
  setLayout(layout: StageLayout): void;
  /** Renders only while running; pause it when the stage is off screen. */
  setRunning(running: boolean): void;
  /** Screen position in CSS pixels of the point just under phone `k`. */
  phoneLabel(k: number): { x: number; y: number };
  dispose(): void;
};

type TapUniform = THREE.UniformNode<"vec4", THREE.Vector4>;

const palette = {
  light: { band: "#0040d8", bandLight: "#2d74ff", dust: "#0b5bff", dustAlt: "#6f9dff", edge: "#6fb0ff" },
  dark: { band: "#0a4ff0", bandLight: "#4a8cff", dust: "#3a86ff", dustAlt: "#b8d3ff", edge: "#9cc8ff" },
};

const smooth = (edge0: number, edge1: number, x: number) => {
  const t = Math.min(1, Math.max(0, (x - edge0) / (edge1 - edge0)));
  return t * t * (3 - 2 * t);
};

export async function createStage({ canvas, dark, reducedMotion, onFrame, onTap }: StageOptions): Promise<Stage> {
  const renderer = new THREE.WebGPURenderer({ canvas, antialias: true, alpha: true });
  await renderer.init();
  const backend = (renderer.backend as { isWebGPUBackend?: boolean }).isWebGPUBackend ? "webgpu" : "webgl";
  const coarse = window.matchMedia("(pointer: coarse)").matches;
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, coarse ? 1.75 : 2));
  renderer.setClearColor(0x000000, 0);
  renderer.toneMapping = THREE.NeutralToneMapping;

  const scene = new THREE.Scene();
  const environment = new THREE.PMREMGenerator(renderer);
  scene.environment = environment.fromScene(new RoomEnvironment(), 0.04).texture;
  scene.environmentIntensity = 0.75;
  // A soft key light from the upper left gives the band's edges a crisp highlight.
  const key = new THREE.DirectionalLight(0xffffff, 1.6);
  key.position.set(-4, 6, 7);
  scene.add(key);

  const camera = new THREE.PerspectiveCamera(32, 1, 0.1, 100);
  camera.position.set(0, 0, 10);

  // Everything turns together, so the particles sit exactly on the solid m.
  const group = new THREE.Group();
  scene.add(group);

  // The folded m.
  const band = bandGeometry();
  const geometry = new THREE.BufferGeometry();
  geometry.setAttribute("position", new THREE.BufferAttribute(band.positions, 3));
  geometry.setAttribute("normal", new THREE.BufferAttribute(band.normals, 3));
  geometry.setAttribute("along", new THREE.BufferAttribute(band.along, 1));
  geometry.setIndex(new THREE.BufferAttribute(band.indices, 1));

  const bandColor = uniform(new THREE.Color());
  const bandLight = uniform(new THREE.Color());
  const edgeColor = uniform(new THREE.Color());
  const dissolve = uniform(1);
  const solid = new THREE.MeshPhysicalNodeMaterial({ roughness: 0.3, metalness: 0, clearcoat: 1, clearcoatRoughness: 0.12 });
  // Lighter where the band faces up, like the logo's two blues, and lighter towards its end.
  solid.colorNode = mix(bandColor, bandLight, clamp(normalLocal.y.mul(0.55).add(attribute("along", "float").mul(0.35)), 0, 1));
  // Dissolving eats the band in noisy patches from the bottom up, with a glowing rim.
  const grain = mx_noise_float(positionLocal.mul(3.2)).mul(0.5).add(0.5).mul(0.8).add(positionLocal.y.add(1.2).mul(0.12));
  const threshold = dissolve.mul(1.25).sub(0.12);
  solid.opacityNode = grain;
  solid.alphaTestNode = threshold;
  solid.emissiveNode = edgeColor.mul(smoothstep(0.07, 0, grain.sub(threshold)).mul(dissolve.greaterThan(0.001).select(2.2, 0)));
  const mesh = new THREE.Mesh(geometry, solid);
  group.add(mesh);

  // The particles.
  const count = coarse || backend === "webgl" ? 26000 : 60000;
  let narrow = window.innerWidth < window.innerHeight * 0.95;
  const targets = particleTargets(count, narrow);
  const onM = instancedArray(targets.m, "vec4");
  const onPhones = instancedArray(targets.phones, "vec4");
  const onGlobe = instancedArray(targets.globe, "vec4");
  const meta = instancedArray(targets.meta, "vec4");
  const time = uniform(0);
  const intro = uniform(reducedMotion ? 1 : 0);
  const toPhones = uniform(0);
  const toGlobe = uniform(0);
  const agent = uniform(0);
  const drift = uniform(reducedMotion ? 0 : 1);
  const dust = uniform(0.35);
  const rayOrigin = uniform(new THREE.Vector3());
  const rayDirection = uniform(new THREE.Vector3(0, 0, -1));
  const push = uniform(0);
  const taps = [0, 1, 2].map(() => uniform(new THREE.Vector4(0, 0, 0, -100))) as [TapUniform, TapUniform, TapUniform];

  /** 0 to 1 over the step, but particle by particle: each starts a little later than the one before. */
  const staggered = (progress: THREE.Node<"float">, delay: THREE.Node<"float">, spread: number) =>
    smoothstep(0, 1, clamp(progress.mul(spread + 1).sub(delay.mul(spread)), 0, 1));

  /**
   * Where particle `i` is and how bright, from its three targets and the story's state. Shared by the
   * WebGPU compute shader and the WebGL vertex shader; call it inside a `Fn`.
   */
  const simulate = (
    i: typeof instanceIndex,
    info: THREE.Node<"vec4">,
    m: THREE.Node<"vec4">,
    phone: THREE.Node<"vec4">,
    globe: THREE.Node<"vec4">,
  ) => {
    const seed = info.x;
    const scatter = vec3(hash(i.add(11)), hash(i.add(23)), hash(i.add(37))).mul(2).sub(1);

    const s0 = staggered(intro, seed, 1.4);
    const s1 = staggered(toPhones, fract(seed.mul(7.13)), 0.9);
    const s2 = staggered(toGlobe, fract(seed.mul(3.71)), 0.9);

    // The globe turns slowly.
    const spin = time.mul(0.1).add(0.6);
    const turned = vec3(globe.x.mul(cos(spin)).add(globe.z.mul(sin(spin))), globe.y, globe.z.mul(cos(spin)).sub(globe.x.mul(sin(spin))));

    // On arrival they gather from a cloud deep behind the m, clear of the headline.
    const start = m.xyz.add(scatter.mul(vec3(2.4, 1.2, 3))).add(vec3(0, -0.4, -5));
    const base = mix(mix(mix(start, m.xyz, s0), phone.xyz, s1), turned, s2).toVar();

    // Mid-flight the particles swirl out and back.
    const flight = sin(s0.mul(PI)).mul(0.6).add(sin(s1.mul(PI))).add(sin(s2.mul(PI)));
    base.addAssign(scatter.mul(flight.mul(0.5)));
    base.addAssign(mx_noise_vec3(base.mul(0.55).add(vec3(0, time.mul(0.25), seed.mul(4)))).mul(flight.mul(0.45)));
    // At rest they breathe a little.
    base.addAssign(mx_noise_vec3(base.mul(1.3).add(vec3(time.mul(0.12), 0, 0))).mul(drift.mul(0.014)));

    // An agent's tap: a ring that runs out over the phone's screen.
    const which = info.y;
    const first = float(1).sub(step(0.5, which));
    const third = step(1.5, which);
    const tap = taps[0].mul(first).add(taps[1].mul(float(1).sub(first).sub(third))).add(taps[2].mul(third));
    const age = time.sub(tap.w);
    const reach = length(base.xy.sub(tap.xy));
    const ring = sin(reach.mul(20).sub(age.mul(8))).mul(exp(reach.mul(-3))).mul(exp(age.mul(-1.4))).mul(smoothstep(0, 0.08, age));
    const ripple = ring.mul(agent).mul(s1).mul(float(1).sub(s2));
    base.addAssign(vec3(base.xy.sub(tap.xy).div(max(reach, 0.001)).mul(ripple.mul(0.035)), ripple.mul(0.06)));

    // Brightness: dim dust on the solid m, full once free; arcs carry travelling light.
    const arc = info.z;
    const pulse = smoothstep(0.82, 1, fract(arc.sub(time.mul(0.4)))).mul(1.6);
    // The far side of the globe fades, so it reads as a sphere rather than a tangle.
    const facing = mix(0.18, 1, smoothstep(-1.3, 0.9, turned.z));
    const globeLight = mix(globe.w, float(0.35).add(pulse), step(0, arc)).mul(facing);
    const lit = mix(mix(m.w.mul(mix(dust, 1, s1)), phone.w, s1), globeLight, s2);
    return { base, lit: lit.add(ripple.abs().mul(1.4)).add(flight.mul(0.25)) };
  };

  const dustColor = uniform(new THREE.Color());
  const dustAlt = uniform(new THREE.Color());
  const size = uniform(0.017);
  const opacity = uniform(1);
  const sprites = new THREE.SpriteNodeMaterial({ transparent: true, depthWrite: false });
  const perParticle = meta.toAttribute();
  let brightness: THREE.Node<"float">;
  let compute: THREE.ComputeNode | null = null;

  if (backend === "webgpu") {
    // WebGPU: a compute shader moves the particles, with a spring that lets the pointer push them.
    const offset = instancedArray(count, "vec3");
    const velocity = instancedArray(count, "vec3");
    const position = instancedArray(count, "vec3");
    const light = instancedArray(count, "float");
    compute = Fn(() => {
      const i = instanceIndex;
      const { base, lit } = simulate(i, meta.element(i), onM.element(i), onPhones.element(i), onGlobe.element(i));
      const off = offset.element(i);
      const vel = velocity.element(i);
      const toParticle = base.add(off).sub(rayOrigin);
      const away = toParticle.sub(rayDirection.mul(dot(toParticle, rayDirection)));
      const distance = max(length(away), 0.0001);
      const force = float(1).sub(smoothstep(0, 0.85, distance)).mul(push);
      vel.addAssign(away.div(distance).mul(force.mul(0.02)));
      vel.addAssign(off.mul(-0.05));
      vel.mulAssign(0.88);
      off.addAssign(vel);
      position.element(i).assign(base.add(off));
      light.element(i).assign(lit);
    })().compute(count);
    sprites.positionNode = position.toAttribute();
    brightness = light.toAttribute();
  } else {
    // WebGL 2 cannot feed this many buffers back, so the vertex shader places each particle itself:
    // the same motion, minus the pointer's push, which needs state from frame to frame.
    const light = varyingProperty("float", "vParticleLight");
    sprites.positionNode = Fn(() => {
      const { base, lit } = simulate(instanceIndex, perParticle, onM.toAttribute(), onPhones.toAttribute(), onGlobe.toAttribute());
      light.assign(lit);
      return base;
    })();
    brightness = light;
  }
  sprites.scaleNode = size.mul(perParticle.w).mul(brightness.mul(0.35).add(0.75));
  sprites.colorNode = mix(dustColor, dustAlt, smoothstep(0.75, 1, perParticle.x));
  sprites.opacityNode = clamp(brightness, 0, 1.6).mul(opacity).mul(shapeCircle() as THREE.Node<"float">);
  const particles = new THREE.Sprite(sprites);
  particles.count = count;
  particles.frustumCulled = false;
  group.add(particles);

  let darkMode = dark;
  const setDark = (isDark: boolean) => {
    darkMode = isDark;
    const colors = isDark ? palette.dark : palette.light;
    bandColor.value.set(colors.band);
    bandLight.value.set(colors.bandLight);
    edgeColor.value.set(colors.edge);
    dustColor.value.set(colors.dust);
    dustAlt.value.set(colors.dustAlt);
    // Light particles glow on black; on white they need to be solid ink.
    sprites.blending = isDark ? THREE.AdditiveBlending : THREE.NormalBlending;
    opacity.value = isDark ? 0.95 : 0.8;
    sprites.needsUpdate = true;
  };
  setDark(dark);

  // State that eases towards its target every frame.
  const state: StoryState = { dissolve: 0, toPhones: 0, agent: 0, toGlobe: 0 };
  const goal: StoryState = { ...state };
  let pointer: { x: number; y: number } | null = null;
  const tilt = new THREE.Vector2();
  let pushing = 0;
  let width = 1;
  let height = 1;
  const clock = new THREE.Timer();
  const startedAt = performance.now();
  const rand = random(3);
  let nextTap = 0;
  let tapPhone = 0;
  let placements = phonePlacements(narrow);
  let layout: StageLayout | null = null;

  const labelPoint = new THREE.Vector3();
  /** How big each object is, in world units at scale 1, with room for its sway. */
  const sizes = {
    m: { width: 3.0, height: 2.7, center: -0.1, max: 1.1 },
    phones: { width: 6.0, height: 2.8, center: 0, max: 1.05 },
    phonesNarrow: { width: 4.3, height: 2.8, center: 0, max: 1.05 },
    globe: { width: 3.6, height: 3.4, center: 0.05, max: 1.1 },
  };
  type Size = (typeof sizes)["m"];
  const visibleHeight = () => 2 * camera.position.z * Math.tan(THREE.MathUtils.degToRad(camera.fov / 2));
  /** The scale and height that center `size` in `region` without overflowing the width. */
  const fit = (region: Region | undefined, size: Size) => {
    const [top, bottom] = region ?? [height * 0.45, height];
    const perPixel = visibleHeight() / height;
    const scale = Math.min(size.max, ((bottom - top) * perPixel) / size.height, (width * 0.88 * perPixel) / size.width);
    return { scale, y: (height / 2 - (top + bottom) / 2) * perPixel - size.center * scale };
  };
  const toScreen = (p: Vec3) => {
    labelPoint.set(p[0], p[1], p[2]).applyMatrix4(group.matrixWorld).project(camera);
    return { x: ((labelPoint.x + 1) / 2) * width, y: ((1 - labelPoint.y) / 2) * height };
  };

  const raycaster = new THREE.Raycaster();
  const inverse = new THREE.Matrix4();

  function frame() {
    clock.update();
    const now = clock.getElapsed();
    const delta = Math.min(clock.getDelta(), 0.05);
    const ease = 1 - Math.exp(-delta * 7);
    for (const key of Object.keys(state) as (keyof StoryState)[]) {
      state[key] += (goal[key] - state[key]) * (reducedMotion ? 1 : ease);
    }

    // Arrival: the particles gather into the m, then it turns solid.
    const introProgress = reducedMotion ? 1 : Math.min(1, (performance.now() - startedAt) / 2600);
    intro.value = introProgress;
    time.value = now;
    toPhones.value = state.toPhones;
    toGlobe.value = state.toGlobe;
    agent.value = state.agent;
    dissolve.value = Math.max(1 - smooth(0.55, 1, introProgress), state.dissolve);
    // On the solid m the particles are a faint shimmer; additive light on black needs even less.
    const shimmer = darkMode ? 0.08 : 0.2;
    dust.value = shimmer + dissolve.value * (1 - shimmer);

    // The m and the phones lean towards the pointer and sway a little on their own.
    tilt.lerp(pointer ?? { x: 0, y: 0 }, reducedMotion ? 1 : ease * 0.5);
    const idle = reducedMotion ? 0 : 1;
    const solidness = 1 - state.toPhones;
    group.rotation.y = (Math.sin(now * 0.35) * 0.22 * solidness + tilt.x * (0.28 - state.toGlobe * 0.2)) * idle;
    group.rotation.x = (0.08 * solidness - tilt.y * 0.12 + Math.sin(now * 0.27) * 0.04 * solidness) * idle;

    // Framing: each object fills the space its chapter's text leaves free.
    const fitM = fit(layout?.m, sizes.m);
    const phonesRegion = layout ? mixRegion(layout.devices, layout.agent, state.agent) : undefined;
    const fitPhones = fit(phonesRegion, narrow ? sizes.phonesNarrow : sizes.phones);
    const fitGlobe = fit(layout?.globe, sizes.globe);
    group.scale.setScalar(mix3(fitM.scale, fitPhones.scale, fitGlobe.scale, state.toPhones, state.toGlobe));
    group.position.y = mix3(fitM.y, fitPhones.y, fitGlobe.y, state.toPhones, state.toGlobe);
    mesh.visible = dissolve.value < 0.999;

    // Taps while the agent chapter is on screen.
    if (state.agent > 0.5 && now > nextTap) {
      nextTap = now + 1.3;
      tapPhone = (tapPhone + 1) % 3;
      const point = screenPoint(item(placements, tapPhone), rand);
      item(taps, tapPhone).value.set(point[0], point[1], point[2], now);
      onTap?.(tapPhone, toScreen(point));
    }

    // The pointer's ray in the group's own space.
    pushing += ((pointer && !reducedMotion ? 1 : 0) - pushing) * ease;
    push.value = pushing;
    if (pointer) {
      group.updateMatrixWorld();
      raycaster.setFromCamera(new THREE.Vector2(pointer.x, pointer.y), camera);
      inverse.copy(group.matrixWorld).invert();
      rayOrigin.value.copy(raycaster.ray.origin).applyMatrix4(inverse);
      rayDirection.value.copy(raycaster.ray.direction).transformDirection(inverse);
    }

    if (compute) renderer.compute(compute);
    renderer.render(scene, camera);
    onFrame?.(stage);
  }

  const stage: Stage = {
    backend,
    setState(next) {
      Object.assign(goal, next);
    },
    setPointer(next) {
      pointer = next;
    },
    setDark,
    resize(w, h) {
      width = Math.max(1, w);
      height = Math.max(1, h);
      renderer.setSize(width, height, false);
      camera.aspect = width / height;
      camera.updateProjectionMatrix();
      const isNarrow = width < height * 0.95;
      if (isNarrow !== narrow) {
        narrow = isNarrow;
        placements = phonePlacements(narrow);
        const { phones, phoneOf } = phoneTargets(count, narrow);
        const buffer = onPhones.value as THREE.StorageInstancedBufferAttribute;
        (buffer.array as Float32Array).set(phones);
        buffer.needsUpdate = true;
        const info = meta.value as THREE.StorageInstancedBufferAttribute;
        const array = info.array as Float32Array;
        phoneOf.forEach((k, i) => (array[i * 4 + 1] = k));
        info.needsUpdate = true;
      }
    },
    setRunning(running) {
      renderer.setAnimationLoop(running ? frame : null);
    },
    setLayout(next) {
      layout = next;
    },
    phoneLabel(k) {
      return toScreen(place([0, -1.35, 0], item(placements, k)));
    },
    dispose() {
      renderer.setAnimationLoop(null);
      geometry.dispose();
      solid.dispose();
      sprites.dispose();
      environment.dispose();
      scene.environment?.dispose();
      renderer.dispose();
    },
  };
  return stage;
}

function mixRegion(a: Region, b: Region, t: number): Region {
  return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
}

/** Interpolates the m's value to the phones' and then the globe's. */
function mix3(m: number, phones: number, globe: number, toPhones: number, toGlobe: number) {
  const first = m + (phones - m) * toPhones;
  return first + (globe - first) * toGlobe;
}
