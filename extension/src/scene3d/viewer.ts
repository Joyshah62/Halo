// Halo's 3D explorer. One page, used three ways: inside the iPad app (where the app draws everything
// around the model and listens for touches), in an extension iframe, and on its own.
// Every model is made of "pieces"; each piece belongs to a part from the shared catalog. Touching a
// piece selects its part, and the host (app or extension) is told so the student can ask Halo about it.
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';
import { catalog, cleanScene3D } from '../../../shared/scene3d/schema.js';

type View = 'whole' | 'inside' | 'half' | 'apart';
type Layer = 'cortex' | 'stem' | 'deep' | 'solid' | 'shell';
interface Part { label: string; detail: string; group?: string }
interface Entry { title: string; summary: string; source: string; kind?: string; credit?: string; parts: Record<string, Part> }
interface Piece {
  mesh: THREE.Mesh; material: THREE.MeshPhysicalMaterial; cap?: THREE.Mesh;
  part: string; layer: Layer; side: 'L' | 'R' | 'M'; base: THREE.Color; alpha: number; centre: THREE.Vector3;
  // Where this piece is heading; the frame loop eases toward these.
  color: THREE.Color; opacity: number; shown: number; glow: number; offset: THREE.Vector3; halved: boolean;
}

const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const models = catalog as Record<string, Entry>;
let raw: any;
try { raw = JSON.parse(decodeURIComponent(location.hash.slice(1))); } catch { raw = null; }
const spec = cleanScene3D(raw);
const embed = raw?.embed === true;
if (embed) document.body.classList.add('embed');

/** Tells whoever is showing this page (the iPad app, or the extension page around the iframe). */
function tell(message: Record<string, unknown>) {
  try { (window as any).webkit?.messageHandlers?.halo?.postMessage(message); } catch { /* not in the app */ }
  if (parent !== window) parent.postMessage({ halo3d: message }, '*');
}

const CORAL = new THREE.Color('#f0603c'), QUIET = new THREE.Color('#e6dfd2');
const BRAIN_COLORS: Record<string, string> = {
  frontal: '#efb199', motor: '#de8fa0', somatosensory: '#ecc67c', parietal: '#8fc9bc', temporal: '#aacb8a', occipital: '#ab9ddb',
  cingulate: '#dba8c6', insula: '#c99fb6', cerebellum: '#93b0d6', midbrain: '#cfc09a', pons: '#dccaa2', medulla: '#c6b48c',
  'corpus-callosum': '#f3ecda', thalamus: '#8db2dc', hypothalamus: '#e59c78', pituitary: '#dd8686', pineal: '#a88cd2',
  hippocampus: '#7cc19e', amygdala: '#e88a8a', fornix: '#f0e0b0', caudate: '#9db6e2', putamen: '#b3a2de',
  'globus-pallidus': '#8cc8ca', ventricles: '#a6d3ea', optic: '#f1d98c',
};
/** The view in which a part can actually be seen, used when Halo (not a finger) points at it. */
const BEST_VIEW: Record<string, View> = {
  cingulate: 'half', 'corpus-callosum': 'half', thalamus: 'half', hypothalamus: 'half', pituitary: 'half', pineal: 'half', fornix: 'half',
  insula: 'inside', hippocampus: 'inside', amygdala: 'inside', caudate: 'inside', putamen: 'inside', 'globus-pallidus': 'inside', ventricles: 'inside',
};
const FROM_BELOW = new Set(['optic']);
const VIEWS: [View, string][] = [['whole', 'Whole'], ['inside', 'See inside'], ['half', 'Cut in half'], ['apart', 'Pull apart']];
const BRAIN_SCALE = 4.4;

if (!spec) {
  $('title').textContent = 'This 3D model is unavailable';
  $('caption').textContent = 'Return to the explanation and ask Halo for a diagram.';
  for (const id of ['viewport', 'parts', 'detail']) $(id).hidden = true;
  document.querySelector('.toolbar')?.remove(); document.querySelector('footer')?.remove();
  tell({ type: 'failed' });
} else {
  const entry = models[spec.model];
  const isBrain = spec.model === 'brain';
  $('title').textContent = entry.title;
  $('caption').textContent = spec.caption || entry.summary;
  $('source').setAttribute('href', entry.source);
  $('credit').textContent = entry.credit || 'Selected structures shown; shapes, spacing and signal timing are simplified.';
  $('badge').textContent = entry.kind === 'anatomy' ? 'REAL ANATOMY · COLORS ARE FOR TEACHING' : 'TEACHING SCHEMATIC · NOT TO SCALE';

  const pieces: Piece[] = [];
  const buttons = new Map<string, HTMLButtonElement>();
  const viewButtons = new Map<View, HTMLButtonElement>();
  let renderer: THREE.WebGLRenderer | undefined;
  let controls: OrbitControls | undefined;
  let active = '', hover = '', view: View = 'whole';
  let running = false, disposed = false, visible = true, last = 0, touched = false;
  let tracing = false, traceStart = 0;
  let anchor: { piece: Piece; local: THREE.Vector3 } | null = null;
  let flight: { start: number; seconds: number; fromDir: THREE.Vector3; turn: THREE.Quaternion; fromDist: number; toDist: number; fromTarget: THREE.Vector3; toTarget: THREE.Vector3 } | null = null;
  const viewport = $('viewport'), label = $('label'), signal = $('signal') as HTMLButtonElement;
  const scene = new THREE.Scene();
  const root = new THREE.Group(); scene.add(root);
  const camera = new THREE.PerspectiveCamera(isBrain ? 30 : 38, 1, 0.1, 100);
  scene.add(camera);
  const cut = new THREE.Plane(new THREE.Vector3(-1, 0, 0), 0.004);
  const raycaster = new THREE.Raycaster();
  const homeDir = (isBrain ? new THREE.Vector3(0.82, 0.3, 0.62) : spec.model === 'neuron' ? new THREE.Vector3(0, 0.21, 0.98) : new THREE.Vector3(0.08, 0.27, 0.96)).normalize();
  const baseDistance = isBrain ? 11.2 : spec.model === 'neuron' ? 13.1 : 8.9;
  let fit = 1;
  const homeDistance = () => baseDistance * fit;
  const pulse = new THREE.Mesh(new THREE.SphereGeometry(0.115, 16, 12), new THREE.MeshBasicMaterial({ color: '#f8bd46', depthTest: false }));
  pulse.renderOrder = 3; pulse.visible = false; root.add(pulse);
  const stops = [new THREE.Vector3(-1.8, 0, 0), new THREE.Vector3(2.8, 0, 0), new THREE.Vector3(3.65, 0.8, 0.15)];

  // MARK: pieces
  function piece(geometry: THREE.BufferGeometry, part: string, color: string, options: { layer?: Layer; side?: 'L' | 'R' | 'M'; alpha?: number; centre?: THREE.Vector3; shaded?: boolean } = {}) {
    const alpha = options.alpha ?? 1;
    const material = new THREE.MeshPhysicalMaterial({
      color, vertexColors: options.shaded === true, roughness: 0.56, metalness: 0, clearcoat: 0.28, clearcoatRoughness: 0.42,
      sheen: 0.35, sheenRoughness: 0.55, sheenColor: new THREE.Color('#ffe2d6'), emissive: CORAL, emissiveIntensity: 0,
      transparent: alpha < 1, opacity: alpha, depthWrite: alpha === 1,
    });
    const mesh = new THREE.Mesh(geometry, material);
    const made: Piece = { mesh, material, part, layer: options.layer ?? (alpha < 1 ? 'shell' : 'solid'), side: options.side ?? 'M', base: new THREE.Color(color), alpha,
      centre: options.centre ?? new THREE.Vector3(), color: new THREE.Color(color), opacity: alpha, shown: alpha, glow: 0, offset: new THREE.Vector3(), halved: false };
    mesh.userData.piece = made;
    pieces.push(made); root.add(mesh); return made;
  }
  function ball(part: string, color: string, position: number[], scale: number[], alpha = 1) {
    const made = piece(new THREE.SphereGeometry(1, 40, 28), part, color, { alpha });
    made.mesh.geometry.scale(scale[0], scale[1], scale[2]).translate(position[0], position[1], position[2]);
    made.centre.set(position[0], position[1], position[2]); return made;
  }
  function tube(part: string, color: string, points: number[][], radius: number) {
    const curve = new THREE.CatmullRomCurve3(points.map(p => new THREE.Vector3(p[0], p[1], p[2])));
    const made = piece(new THREE.TubeGeometry(curve, 32, radius, 10, false), part, color);
    made.centre.copy(curve.getPoint(0.5)); return made;
  }
  function buildNeuron() {
    ball('soma', '#d5a49a', [-1.8, 0, 0], [0.7, 0.65, 0.58]);
    ball('soma', '#846ea8', [-1.85, 0.06, 0.48], [0.23, 0.23, 0.17]);
    for (let i = 0; i < 7; i++) {
      const angle = (i / 6) * Math.PI * 1.5 + Math.PI / 4;
      const y = Math.sin(angle), z = Math.cos(angle) * 0.65;
      const tip = [-3.4 + (i % 2) * 0.35, y * 1.6, z * 1.7];
      tube('dendrites', '#7d9f90', [[-2.1, y * 0.2, z * 0.2], [-2.65, y * 0.85, z], tip], 0.065);
      tube('dendrites', '#7d9f90', [[-2.65, y * 0.85, z], [tip[0] + 0.1, tip[1] + 0.4, tip[2] - 0.4]], 0.04);
    }
    tube('axon', '#b79763', [[-1.2, 0, 0], [0.7, 0, 0], [2.8, 0, 0]], 0.085);
    for (let i = 0; i < 5; i++) ball('myelin', '#ecd3a0', [-0.55 + i * 0.66, 0, 0], [0.26, 0.19, 0.19]);
    for (const [y, z] of [[0.8, 0.15], [-0.7, 0.4], [0.05, -0.8]]) {
      tube('terminals', '#7d9f90', [[2.7, 0, 0], [3.2, y * 0.6, z * 0.5], [3.65, y, z]], 0.06);
      ball('terminals', '#af7f97', [3.65, y, z], [0.14, 0.14, 0.14]);
    }
    signal.hidden = false;
  }
  function buildCell() {
    ball('membrane', '#87aa97', [0, 0, 0], [2.4, 1.9, 1.8], 0.14);
    ball('nucleus', '#a18bbb', [-0.55, 0.15, 0.15], [0.78, 0.72, 0.7]);
    ball('nucleus', '#735d95', [-0.5, 0.27, 0.7], [0.22, 0.22, 0.17]);
    for (const [x, y, z] of [[1.2, 0.55, 0.4], [0.65, -0.95, 0.6], [-1.4, -0.7, -0.4]]) {
      ball('mitochondria', '#d4a174', [x, y, z], [0.48, 0.24, 0.26]);
      tube('mitochondria', '#996a45', Array.from({ length: 7 }, (_, i) => [x - 0.32 + i * 0.1, y + (i % 2 ? 0.1 : -0.1), z + 0.22]), 0.025);
    }
    for (let i = 0; i < 22; i++) {
      const a = i * 2.39996, r = 1.15 + (i % 3) * 0.15;
      ball('ribosomes', '#6c8f81', [Math.cos(a) * r, Math.sin(a) * r * 0.85, ((i % 5) - 2) * 0.4], [0.065, 0.065, 0.065]);
    }
  }
  /** The brain ships as one gzipped binary inside a script (see shared/scene3d/tools/build_brain.py). */
  async function buildBrain() {
    $('loading').hidden = false;
    await new Promise<void>((resolve, reject) => {
      const script = document.createElement('script'); script.src = 'brain-data.js';
      script.onload = () => resolve(); script.onerror = () => reject(new Error('brain data missing'));
      document.head.append(script);
    });
    const packed = Uint8Array.from(atob((self as any).HALO_BRAIN as string), c => c.charCodeAt(0));
    (self as any).HALO_BRAIN = undefined;
    const buffer = await new Response(new Blob([packed]).stream().pipeThrough(new DecompressionStream('gzip'))).arrayBuffer();
    const headLength = new DataView(buffer).getUint32(0, true);
    const head = JSON.parse(new TextDecoder().decode(new Uint8Array(buffer, 4, headLength))) as
      { quantum: number; meshes: { part: string; layer: Layer; side: 'L' | 'R' | 'M'; vertices: number; indices: number; wide: boolean; centre: number[] }[] };
    let at = 4 + headLength;
    const pad = (n: number) => n + ((4 - (n % 4)) % 4);
    for (const m of head.meshes) {
      const quantized = new Int16Array(buffer, at, m.vertices * 3); at += pad(m.vertices * 6);
      const index = m.wide ? new Uint32Array(buffer, at, m.indices) : new Uint16Array(buffer, at, m.indices); at += pad(m.indices * (m.wide ? 4 : 2));
      const shade = new Uint8Array(buffer, at, m.vertices); at += pad(m.vertices);
      if (!Object.hasOwn(entry.parts, m.part)) continue;
      const position = new Float32Array(m.vertices * 3), color = new Float32Array(m.vertices * 3);
      for (let i = 0; i < position.length; i++) position[i] = quantized[i] / head.quantum * BRAIN_SCALE;
      for (let i = 0; i < m.vertices; i++) {
        // Baked ambient occlusion: folds and the gaps between gyri are darker, and a touch warmer.
        const open = shade[i] / 255, light = 0.1 + 0.9 * Math.pow(open, 2.1);
        color[i * 3] = Math.min(1, light * (1.06 - 0.06 * open)); color[i * 3 + 1] = light * (0.94 + 0.06 * open); color[i * 3 + 2] = light * (0.9 + 0.1 * open);
      }
      const geometry = new THREE.BufferGeometry();
      geometry.setAttribute('position', new THREE.BufferAttribute(position, 3));
      geometry.setAttribute('color', new THREE.BufferAttribute(color, 3));
      geometry.setIndex(new THREE.BufferAttribute(index.slice(), 1));
      geometry.computeVertexNormals(); geometry.computeBoundingSphere();
      const made = piece(geometry, m.part, BRAIN_COLORS[m.part] || '#d8c8b8', { layer: m.layer, side: m.side, shaded: true,
        centre: new THREE.Vector3(m.centre[0], m.centre[1], m.centre[2]).multiplyScalar(BRAIN_SCALE) });
      if (m.side === 'M') {
        // When the brain is cut in half, the inside of each cut shell is filled with a flat color so it reads as solid.
        const rank = m.part === 'ventricles' ? 0 : 1 + pieces.length;
        const fill = new THREE.Mesh(geometry, new THREE.MeshBasicMaterial({ color: made.base.clone().multiplyScalar(0.8), side: THREE.BackSide, clippingPlanes: [cut],
          polygonOffset: true, polygonOffsetFactor: 0, polygonOffsetUnits: -rank * 6 }));
        fill.visible = false; made.mesh.add(fill); made.cap = fill;
      }
    }
    // A soft shadow on the desk under the model.
    const canvas = document.createElement('canvas'); canvas.width = canvas.height = 128;
    const g = canvas.getContext('2d')!; const fade = g.createRadialGradient(64, 64, 4, 64, 64, 64);
    fade.addColorStop(0, 'rgba(60,45,30,0.34)'); fade.addColorStop(1, 'rgba(60,45,30,0)');
    g.fillStyle = fade; g.fillRect(0, 0, 128, 128);
    const shadow = new THREE.Mesh(new THREE.PlaneGeometry(6.4, 6.4), new THREE.MeshBasicMaterial({ map: new THREE.CanvasTexture(canvas), transparent: true, depthWrite: false, toneMapped: false }));
    shadow.rotation.x = -Math.PI / 2; shadow.position.y = -2.25; shadow.renderOrder = -1; scene.add(shadow);
    $('loading').hidden = true;
  }

  // MARK: how each piece should look right now
  function restyle() {
    const activeLayer = pieces.find(p => p.part === active)?.layer;
    for (const p of pieces) {
      const chosen = p.part === active;
      p.color.copy(chosen ? CORAL : p.base);
      if (!chosen && active) p.color.lerp(QUIET, 0.5);
      if (!chosen && p.part === hover) p.color.lerp(new THREE.Color('#ffffff'), 0.28);
      p.glow = chosen ? 0.32 : 0;
      let opacity = p.alpha;
      if (view === 'inside' && p.layer === 'cortex') opacity = chosen ? 0.55 : 0.09;
      if (view === 'inside' && p.part === 'cerebellum') opacity = chosen ? 0.7 : 0.3;
      // With something deep picked out, its neighbours turn to glass so nothing stands in front of it.
      if (view === 'inside' && p.layer === 'deep' && !chosen && activeLayer === 'deep') opacity = 0.2;
      if (view === 'half' && p.side === 'L') opacity = 0;
      p.opacity = opacity;
      p.offset.set(0, 0, 0);
      if (view === 'apart') { p.offset.copy(p.centre).multiplyScalar(0.42); p.offset.x += p.side === 'L' ? 0.4 : p.side === 'R' ? -0.4 : 0; }
      const halved = view === 'half' && p.side === 'M';
      if (p.cap) {
        p.cap.visible = halved;
        (p.cap.material as THREE.MeshBasicMaterial).color.copy(chosen ? CORAL : p.base).multiplyScalar(chosen ? 0.86 : 0.8);
        if (p.halved !== halved) { p.halved = halved; p.material.clippingPlanes = halved ? [cut] : null; p.material.needsUpdate = true; }
      }
    }
    wake();
  }

  function showPart() {
    for (const [id, button] of buttons) button.setAttribute('aria-pressed', String(id === active));
    $('part-title').textContent = active ? entry.parts[active].label : 'Touch any part';
    $('part-detail').textContent = active ? entry.parts[active].detail : entry.summary;
    const ask = $('ask'); ask.replaceChildren();
    // Only a host can answer; on its own the page just describes.
    ask.hidden = !(active && parent !== window);
    if (!ask.hidden) {
      const name = entry.parts[active].label.toLowerCase();
      for (const question of [`What does the ${name} do?`, `What happens if the ${name} is damaged?`, `How does the ${name} connect to the rest?`]) {
        const button = document.createElement('button'); button.textContent = `Ask Halo: ${question}`;
        button.addEventListener('click', () => tell({ type: 'ask', model: spec!.model, part: active, question }));
        ask.append(button);
      }
    }
    label.hidden = !active || !anchor;
    if (active) label.querySelector('span')!.textContent = entry.parts[active].label;
  }

  /** Where the camera should stand to look at a part, and the view that shows it. */
  function vantage(part: string) {
    const mine = pieces.filter(p => p.part === part);
    const wanted: View = isBrain ? (BEST_VIEW[part] ?? (view === 'apart' ? 'apart' : 'whole')) : view;
    const looking = camera.position.clone().sub(controls!.target).normalize();
    if (wanted === 'half') {
      const seen = mine.find(p => p.side === 'M') || mine.find(p => p.side === 'R') || mine[0];
      return { piece: seen, view: wanted, dir: new THREE.Vector3(1, 0.1, 0.16).normalize(), target: new THREE.Vector3(0, seen.centre.y * 0.35, seen.centre.z * 0.35), distance: homeDistance() * 0.84 };
    }
    let seen = mine[0];
    for (const p of mine) if (p.centre.dot(looking) > seen.centre.dot(looking) + 0.01) seen = p;
    const c = seen.centre;
    let dir: THREE.Vector3;
    if (!isBrain) dir = looking;
    else if (FROM_BELOW.has(part)) dir = new THREE.Vector3(0.35, -0.72, 0.6);
    else if (c.length() < 0.75) dir = new THREE.Vector3(c.x >= 0 ? 1 : -1, 0.24, 0.42);
    else { dir = new THREE.Vector3(c.x * 1.5, c.y * 0.55, c.z); dir.normalize(); dir.y = Math.min(0.72, Math.max(-0.22, dir.y)); }
    return { piece: seen, view: wanted, dir: dir.normalize(), target: isBrain ? c.clone().multiplyScalar(0.3) : new THREE.Vector3(), distance: homeDistance() * (isBrain ? (seen.layer === 'deep' ? 0.78 : 0.9) : 1) };
  }
  function fly(dir: THREE.Vector3, distance: number, target: THREE.Vector3, seconds = 1) {
    if (!controls) return;
    const from = camera.position.clone().sub(controls.target);
    const fromDir = from.clone().normalize();
    flight = { start: performance.now(), seconds, fromDir, turn: new THREE.Quaternion().setFromUnitVectors(fromDir, dir), fromDist: from.length(), toDist: distance,
      fromTarget: controls.target.clone(), toTarget: target.clone() };
    controls.autoRotate = false; wake();
  }
  /** The point on a piece that will face the camera once it has arrived: where the name tag is pinned. */
  function facing(p: Piece, eye: THREE.Vector3, at: View) {
    if (at === 'half' && p.side === 'M') return new THREE.Vector3(0, p.centre.y, p.centre.z);
    const held = p.mesh.position.clone();
    p.mesh.position.set(0, 0, 0); p.mesh.updateMatrixWorld(true);
    raycaster.set(eye, p.centre.clone().sub(eye).normalize());
    const hit = raycaster.intersectObject(p.mesh, false)[0];
    p.mesh.position.copy(held); p.mesh.updateMatrixWorld(true);
    return hit ? hit.point.clone() : p.centre.clone();
  }

  function select(part: string | null, by: 'touch' | 'host' | 'button' = 'host', at?: { piece: Piece; point: THREE.Vector3 }) {
    active = part && Object.hasOwn(entry.parts, part) ? part : '';
    anchor = null;
    if (active && controls) {
      if (at) anchor = { piece: at.piece, local: at.point.clone().sub(at.piece.mesh.position) };
      else {
        // Halo (or a button) pointed at it: turn the model, and open it up if the part is hidden inside.
        const stand = vantage(active);
        if (stand.view !== view) setView(stand.view, false);
        fly(stand.dir, stand.distance, stand.target);
        anchor = { piece: stand.piece, local: facing(stand.piece, stand.target.clone().add(stand.dir.clone().multiplyScalar(stand.distance)), stand.view) };
      }
      controls.autoRotate = false;
    }
    showPart(); restyle();
    tell({ type: 'select', model: spec!.model, part: active || null, by });
  }
  function setView(next: View, announce = true) {
    if (!isBrain || !VIEWS.some(v => v[0] === next)) return;
    view = next;
    for (const [id, button] of viewButtons) button.setAttribute('aria-pressed', String(id === view));
    // A name tag pinned to something that is no longer shown would float in the air.
    if (anchor && view === 'half' && anchor.piece.side === 'L') { anchor = null; label.hidden = true; }
    restyle();
    if (announce) {
      if (view === 'half' && controls) fly(new THREE.Vector3(1, 0.12, 0.2).normalize(), homeDistance() * 0.92, new THREE.Vector3());
      else if (view === 'apart' && controls) fly(camera.position.clone().sub(controls.target).normalize(), homeDistance() * 1.32, new THREE.Vector3());
      else if (controls && camera.position.distanceTo(controls.target) > homeDistance() * 1.15) fly(camera.position.clone().sub(controls.target).normalize(), homeDistance(), new THREE.Vector3());
    }
    tell({ type: 'view', view });
  }
  function reset() {
    if (!controls) return;
    if (isBrain && view !== 'whole') setView('whole', false);
    fly(homeDir, homeDistance(), new THREE.Vector3(), 0.8);
    tell({ type: 'view', view });
  }
  function zoom(factor: number) {
    if (!controls) return;
    const from = camera.position.clone().sub(controls.target);
    from.multiplyScalar(factor).clampLength(controls.minDistance, controls.maxDistance);
    camera.position.copy(controls.target).add(from); controls.update(); wake();
  }
  function stopTrace() { tracing = false; pulse.visible = false; signal.textContent = 'Trace signal'; signal.setAttribute('aria-pressed', 'false'); }

  // MARK: the frame loop
  function wake() { if (!running && !disposed && visible && renderer) { running = true; last = performance.now(); requestAnimationFrame(frame); } }
  const projected = new THREE.Vector3();
  function frame(now: number) {
    if (disposed || !visible || !renderer || !controls) { running = false; return; }
    const dt = Math.min(0.05, (now - last) / 1000); last = now;
    const ease = 1 - Math.exp(-dt * 9);
    let moving = controls.autoRotate || tracing || !!active;
    for (const p of pieces) {
      p.material.color.lerp(p.color, ease);
      const glow = p.glow ? p.glow + Math.sin(now / 420) * 0.09 : 0;
      p.material.emissiveIntensity += (glow - p.material.emissiveIntensity) * ease;
      p.shown += (p.opacity - p.shown) * ease;
      if (Math.abs(p.opacity - p.shown) < 0.004) p.shown = p.opacity; else moving = true;
      const solid = p.shown > 0.985;
      if (p.material.transparent === solid) { p.material.transparent = !solid; p.material.needsUpdate = true; }
      p.material.opacity = p.shown; p.material.depthWrite = p.shown > 0.6; p.mesh.visible = p.shown > 0.012;
      p.mesh.renderOrder = solid ? 0 : 1;
      if (p.mesh.position.distanceToSquared(p.offset) > 1e-6) { p.mesh.position.lerp(p.offset, ease); moving = true; } else p.mesh.position.copy(p.offset);
    }
    if (flight) {
      const t = Math.min(1, (now - flight.start) / (flight.seconds * 1000));
      const e = t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
      const dir = flight.fromDir.clone().applyQuaternion(new THREE.Quaternion().slerp(flight.turn, e));
      controls.target.lerpVectors(flight.fromTarget, flight.toTarget, e);
      camera.position.copy(controls.target).addScaledVector(dir, flight.fromDist + (flight.toDist - flight.fromDist) * e);
      if (t >= 1) flight = null;
      moving = true;
    }
    if (tracing) {
      const progress = Math.min(1, (now - traceStart) / 4800), split = 0.78;
      pulse.position.copy(progress < split ? stops[0].clone().lerp(stops[1], progress / split) : stops[1].clone().lerp(stops[2], (progress - split) / (1 - split)));
      if (progress >= 1) stopTrace();
    }
    if (controls.update(dt)) moving = true;
    if (anchor && active) {
      projected.copy(anchor.local).add(anchor.piece.mesh.position).project(camera);
      const w = viewport.clientWidth, h = viewport.clientHeight;
      label.hidden = projected.z > 1;
      label.style.transform = `translate(${((projected.x + 1) / 2 * w).toFixed(1)}px, ${((1 - projected.y) / 2 * h - 14).toFixed(1)}px)`;
    }
    renderer.render(scene, camera);
    if (moving || now - settled < 600) requestAnimationFrame(frame); else running = false;
    if (moving) settled = now;
  }
  let settled = 0;

  function pick(x: number, y: number) {
    const rect = renderer!.domElement.getBoundingClientRect();
    raycaster.setFromCamera(new THREE.Vector2((x - rect.left) / rect.width * 2 - 1, -(y - rect.top) / rect.height * 2 + 1), camera);
    const hits = raycaster.intersectObjects(pieces.filter(p => p.mesh.visible && p.opacity > 0.02).map(p => p.mesh), false)
      .filter(h => !(view === 'half' && (h.object.userData.piece as Piece).side === 'M' && h.point.x > 0.004));
    // Something see-through never blocks what is behind it.
    const hit = hits.find(h => (h.object.userData.piece as Piece).opacity > 0.4) || hits[0];
    return hit ? { piece: hit.object.userData.piece as Piece, point: hit.point } : null;
  }

  // MARK: the page around the model
  let group = '';
  for (const [id, part] of Object.entries(entry.parts)) {
    if (part.group && part.group !== group) { group = part.group; const heading = document.createElement('h3'); heading.textContent = group; $('parts').append(heading); }
    const button = document.createElement('button'); button.textContent = part.label;
    button.addEventListener('click', () => select(id, 'button')); buttons.set(id, button); $('parts').append(button);
  }
  if (isBrain) {
    $('views').hidden = false;
    for (const [id, name] of VIEWS) {
      const button = document.createElement('button'); button.textContent = name; button.setAttribute('aria-pressed', String(id === view));
      button.addEventListener('click', () => setView(id)); viewButtons.set(id, button); $('views').append(button);
    }
  }
  showPart();   // Descriptions stay useful even when WebGL is unavailable.

  function unavailable() {
    $('fallback').hidden = false; $('loading').hidden = true;
    for (const id of ['zoom-in', 'zoom-out', 'reset', 'signal']) ($(id) as HTMLButtonElement).disabled = true;
    $('hint').textContent = 'Choose a part to read about it';
    tell({ type: 'failed' });
  }

  (async () => {
    try {
      renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true, powerPreference: 'high-performance' });
      renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
      renderer.setClearColor(0x000000, 0);
      renderer.toneMapping = THREE.NeutralToneMapping; renderer.toneMappingExposure = 1.05;
      renderer.localClippingEnabled = true;
      const canvas = renderer.domElement;
      viewport.append(canvas);
      canvas.tabIndex = 0;
      canvas.setAttribute('aria-label', '3D model. Arrow keys rotate; plus and minus zoom; Home resets.');
      controls = new OrbitControls(camera, canvas);
      controls.enableDamping = true; controls.dampingFactor = 0.08; controls.enablePan = false; controls.rotateSpeed = 0.75;
      controls.minDistance = isBrain ? 5 : 3; controls.maxDistance = isBrain ? 20 : 24;
      controls.autoRotateSpeed = 0.55;
      controls.addEventListener('start', () => { touched = true; flight = null; controls!.autoRotate = false; wake(); });
      controls.addEventListener('change', wake);

      // Soft studio light from all around, plus a key and a rim that travel with the camera so the shape always reads.
      const pmrem = new THREE.PMREMGenerator(renderer);
      scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture; scene.environmentIntensity = 0.42;
      pmrem.dispose();
      const key = new THREE.DirectionalLight(0xfff0e2, 2.9); key.position.set(-4.5, 6, 5); camera.add(key); camera.add(key.target); key.target.position.set(0, 0, -10);
      const rim = new THREE.DirectionalLight(0xdfe8ff, 1.3); rim.position.set(7, 1, -4); camera.add(rim); camera.add(rim.target); rim.target.position.set(0, 0, -10);

      if (spec.model === 'neuron') buildNeuron(); else if (spec.model === 'animal-cell') buildCell(); else await buildBrain();
      if (disposed) return;

      // Arrive from a little further out, then drift slowly until someone takes hold.
      camera.position.copy(homeDir).multiplyScalar(homeDistance() * 1.5); controls.target.set(0, 0, 0); controls.update();
      $('reset').addEventListener('click', reset);
      $('zoom-in').addEventListener('click', () => zoom(0.85));
      $('zoom-out').addEventListener('click', () => zoom(1.18));
      canvas.addEventListener('keydown', event => {
        if (!['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', '+', '=', '-', 'Home'].includes(event.key)) return;
        event.preventDefault(); flight = null; controls!.autoRotate = false;
        if (event.key === 'Home') reset();
        else if (['+', '=', '-'].includes(event.key)) zoom(event.key === '-' ? 1.18 : 0.85);
        else {
          const spherical = new THREE.Spherical().setFromVector3(camera.position.clone().sub(controls!.target));
          if (event.key === 'ArrowLeft') spherical.theta -= 0.12;
          if (event.key === 'ArrowRight') spherical.theta += 0.12;
          if (event.key === 'ArrowUp') spherical.phi = Math.max(0.1, spherical.phi - 0.12);
          if (event.key === 'ArrowDown') spherical.phi = Math.min(Math.PI - 0.1, spherical.phi + 0.12);
          camera.position.copy(controls!.target).add(new THREE.Vector3().setFromSpherical(spherical)); controls!.update(); wake();
        }
      });
      let down = { x: 0, y: 0, t: 0 };
      canvas.addEventListener('pointerdown', e => { down = { x: e.clientX, y: e.clientY, t: performance.now() }; });
      canvas.addEventListener('pointerup', e => {
        if (Math.hypot(e.clientX - down.x, e.clientY - down.y) > 7 || performance.now() - down.t > 600) return;
        const hit = pick(e.clientX, e.clientY);
        // Touching the empty desk lets go of whatever was held.
        if (hit) select(hit.piece.part, 'touch', hit); else if (active) select(null, 'touch');
      });
      let hoverQueued = false;
      canvas.addEventListener('pointermove', e => {
        if (e.pointerType !== 'mouse' || e.buttons || hoverQueued) return;
        hoverQueued = true;
        requestAnimationFrame(() => {
          hoverQueued = false;
          const part = pick(e.clientX, e.clientY)?.piece.part || '';
          canvas.classList.toggle('pointing', !!part);
          if (part !== hover) { hover = part; restyle(); }
        });
      });
      canvas.addEventListener('pointerleave', () => { if (hover) { hover = ''; restyle(); } });
      signal.addEventListener('click', () => {
        if (tracing) { stopTrace(); wake(); return; }
        select('axon', 'button'); tracing = true; traceStart = performance.now(); pulse.visible = true;
        signal.textContent = 'Stop trace'; signal.setAttribute('aria-pressed', 'true'); wake();
      });
      const observer = new ResizeObserver(() => {
        const { width, height } = viewport.getBoundingClientRect();
        if (!width || !height) return;
        camera.aspect = width / height; camera.updateProjectionMatrix();
        // A narrow panel needs the camera further back to keep the whole model in view.
        const before = fit; fit = Math.max(1, (isBrain ? 1.02 : spec.model === 'neuron' ? 1.6 : 1.1) / camera.aspect);
        // Keep the same framing whether the model is arriving, resting, or being held.
        if (before !== fit) {
          if (flight) flight.toDist *= fit / before;
          else camera.position.copy(controls!.target).addScaledVector(camera.position.clone().sub(controls!.target), fit / before);
        }
        renderer!.setSize(width, height); wake();
      }); observer.observe(viewport);
      const watching = new IntersectionObserver(entries => { visible = entries[0].isIntersecting && !document.hidden; if (visible) wake(); else stopTrace(); });
      watching.observe(viewport);
      document.addEventListener('visibilitychange', () => { visible = !document.hidden; if (visible) wake(); else stopTrace(); });
      canvas.addEventListener('webglcontextlost', e => { e.preventDefault(); stopTrace(); unavailable(); });
      canvas.addEventListener('webglcontextrestored', () => location.reload());
      window.addEventListener('pagehide', () => {
        disposed = true; observer.disconnect(); watching.disconnect(); controls?.dispose();
        scene.traverse(object => { if (object instanceof THREE.Mesh) { object.geometry.dispose();
          for (const mat of Array.isArray(object.material) ? object.material : [object.material]) mat.dispose(); } });
        renderer?.dispose();
      }, { once: true });

      // What the host can do: point at a part, change the view, start over.
      (window as any).halo3d = {
        select: (part: string | null) => select(part, 'host'),
        setView: (next: View) => setView(next),
        reset,
        zoom,
      };
      restyle();
      // The first frames compile the shaders; show the model once it can move smoothly.
      renderer.compile(scene, camera);
      requestAnimationFrame(() => {
        canvas.classList.add('ready');
        fly(homeDir, homeDistance(), new THREE.Vector3(), 1.5);
        if (spec.focus) setTimeout(() => select(spec.focus!, 'host'), 900);
        else controls!.autoRotate = true;
        tell({ type: 'ready', model: spec.model, parts: Object.keys(entry.parts), views: isBrain ? VIEWS.map(v => v[0]) : [] });
      });
    } catch (error) {
      console.error(error);
      renderer?.dispose(); unavailable();
    }
  })();
}
