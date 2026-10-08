import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import ts from 'typescript';

const source = readFileSync(new URL('../src/worker.ts', import.meta.url), 'utf8');
const moduleContext = vm.createContext({ TextEncoder });
vm.runInContext(ts.transpileModule(source
  .replace(/import \{ neon, type NeonQueryFunction \} from "@neondatabase\/serverless";/, '')
  .replace('export default {', 'const worker = {')
  + '\nglobalThis.effects = { gate: CALM_GATE_SCRIPT, glass: meltedGlassScript() };', {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
}).outputText, moduleContext);
const script = name => moduleContext.effects[name].match(/<script>([\s\S]*?)<\/script>/)[1];

// Execute the actual emitted scripts with a controlled clock and asynchronous image pipeline.
function browser({ cores = 8, memory = 8, coarse = false, reduced = false, saveData = false, dpr = 1, stored = null } = {}) {
  let now = 0, sequence = 0, uploads = 0;
  const frames = new Map(), encodes = [], images = [], urls = new Set(), nodes = [], observers = [];
  const classes = new Set();
  const element = tag => {
    const node = { tag, style: {}, attributes: {}, listeners: {},
      setAttribute(k, v) { this.attributes[k] = v; },
      removeAttribute(k) { delete this.attributes[k]; },
      appendChild() {}, addEventListener(k, fn) { this.listeners[k] = fn; },
    };
    nodes.push(node);
    return node;
  };
  const root = element('html');
  root.classList = {
    contains: x => classes.has(x), add: x => classes.add(x),
    toggle(x, on) { if (on) classes.add(x); else classes.delete(x); },
  };
  const document = { documentElement: root, body: element('body'), hidden: false, listeners: {},
    addEventListener(k, fn) { this.listeners[k] = fn; }, createElementNS: (_, tag) => element(tag),
    createElement(tag) {
      const node = element(tag);
      if (tag === 'canvas') {
        node.getContext = () => ({ createImageData: (w, h) => ({ data: new Uint8ClampedArray(w * h * 4) }), putImageData() {} });
        node.toBlob = cb => { uploads++; encodes.push(cb); };
      }
      return node;
    },
  };
  const window = { innerWidth: 1440, innerHeight: 900, listeners: {},
    addEventListener(k, fn) { this.listeners[k] = fn; },
    matchMedia: q => ({ matches: q.includes('reduced-motion') ? reduced : q.includes('hover: none') ? coarse : !coarse, addEventListener() {} }),
    requestAnimationFrame(fn) { const id = ++sequence; frames.set(id, fn); return id; },
  };
  const context = vm.createContext({ window, document, innerWidth: 1440, innerHeight: 900, devicePixelRatio: dpr,
    navigator: { hardwareConcurrency: cores, deviceMemory: memory, connection: { saveData }, userAgentData: { brands: [{ brand: 'Chromium' }] } },
    localStorage: { getItem: () => stored }, performance: { now: () => now },
    requestAnimationFrame: window.requestAnimationFrame, cancelAnimationFrame: id => frames.delete(id),
    MutationObserver: class { constructor(fn) { observers.push(fn); } observe() {} },
    URL: { createObjectURL() { const url = 'blob:' + (++sequence); urls.add(url); return url; }, revokeObjectURL: url => urls.delete(url) },
    Image: class { set src(value) { images.push(this); } },
  });
  vm.runInContext(script('gate'), context);
  vm.runInContext(script('glass'), context);
  const flush = () => { while (encodes.length) encodes.shift()({}); while (images.length) images.shift().onload(); };
  return { classes, document, nodes, frames, urls, flush,
    get uploads() { return uploads; },
    get filter() { return nodes.find(x => x.className === 'melted-glass')?.style.backdropFilter; },
    move() { window.listeners.pointermove?.({ clientX: 400 + now % 500, clientY: 300, pointerType: 'mouse' }); },
    step(ms = 17, finish = true, moving = false) { now += ms; if (moving) this.move(); const pending = [...frames.values()]; frames.clear(); pending.forEach(fn => fn(now)); if (finish) flush(); },
    scroll() { window.listeners.scroll(); },
    calm() { classes.add('cs-calm'); observers.forEach(fn => fn()); },
    hide() { document.hidden = true; document.listeners.visibilitychange(); },
  };
}

test('limited devices, touch, reduced motion and large displays skip glass initialization', () => {
  for (const options of [{ cores: 4 }, { memory: 4 }, { coarse: true }, { reduced: true }, { saveData: true }, { dpr: 3 }, { stored: '1' }]) {
    const b = browser(options);
    assert.ok(b.classes.has('cs-lite') || b.classes.has('cs-calm'));
    assert.equal(b.nodes.some(n => n.tag === 'canvas'), false);
    b.move();
    assert.equal(b.frames.size, 0);
  }
});

test('fast pointer input stays within 30 uploads per second and stops after idle', () => {
  const b = browser();
  for (let i = 0; i < 250; i++) { b.move(); b.step(4); }
  assert.ok(b.uploads > 20 && b.uploads <= 31, String(b.uploads));
  assert.match(b.filter, /melted-glass/);
  b.step(1000);
  assert.equal(b.filter, 'none');
  assert.equal(b.frames.size, 0);
  assert.equal(b.urls.size, 0);
  b.move(); b.step();
  assert.match(b.filter, /melted-glass/, 'movement restarts the effect');
});

test('scroll, calm mode and hidden tabs cancel work and reject stale image uploads', () => {
  for (const action of ['scroll', 'calm', 'hide']) {
    const b = browser();
    b.move(); b.step(17, false); // Encoding is still in flight when the user leaves.
    b[action]();
    b.flush();
    assert.equal(b.filter, 'none', action);
    assert.equal(b.frames.size, 0, action);
    assert.equal(b.urls.size, 0, action);
  }
});

test('sustained slow frames automatically fall back to static effects', () => {
  const b = browser();
  for (let i = 0; i < 24; i++) { b.step(110, true, true); }
  assert.ok(b.classes.has('cs-lite'));
  assert.equal(b.filter, 'none');
  assert.equal(b.frames.size, 0);
  assert.equal(b.urls.size, 0);
});
