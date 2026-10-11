// Logic tests that run without Electron: `npm test` (or `node scripts/test.js`).
const assert = require('assert');
const { TimerEngine, formatTime, normaliseSegment } = require('../src/main/engine');
const { parsePacket, toCommand } = require('../src/main/osc');
const { isNewer, clean, pickAsset } = require('../src/main/updater');

let passed = 0;
function test(name, fn) {
  try { fn(); passed++; } catch (e) { console.error(`✗ ${name}\n  ${e.stack}`); process.exitCode = 1; }
}

// ---- time formatting
test('formatTime', () => {
  assert.strictEqual(formatTime(0), '00:00');
  assert.strictEqual(formatTime(59.4), '00:59');
  assert.strictEqual(formatTime(59.4, true), '01:00');
  assert.strictEqual(formatTime(3725), '1:02:05');
});

// ---- engine with a fake clock
function makeEngine(segments) {
  let t = 1_000_000;
  const e = new TimerEngine({ segments }, () => t);
  return { e, advance: (s) => { t += s * 1000; e.tick(); } };
}

test('countdown runs, warns, goes overtime', () => {
  const { e, advance } = makeEngine([{ title: 'A', duration: 60, yellowAt: 20, redAt: 5 }, { title: 'B', duration: 30 }]);
  const sounds = [];
  e.on('sound', (s) => sounds.push(s));
  assert.strictEqual(e.displayText, '01:00');
  e.start();
  advance(30);
  assert.strictEqual(e.displayText, '00:30');
  assert.strictEqual(e.phase, 'normal');
  advance(15);
  assert.strictEqual(e.phase, 'warning');
  advance(12);
  assert.strictEqual(e.phase, 'critical');
  advance(5);
  assert.strictEqual(e.phase, 'overtime');
  assert.strictEqual(e.displayText, '+00:02');
  assert.deepStrictEqual(sounds, ['warning', 'critical', 'zero']);
});

test('pause / resume / add time / reset', () => {
  const { e, advance } = makeEngine([{ title: 'A', duration: 100 }]);
  e.start(); advance(10); e.pause(); advance(50);
  assert.strictEqual(e.displayText, '01:30');
  e.addTime(60);
  assert.strictEqual(e.displayText, '02:30');
  e.start(); advance(30);
  assert.strictEqual(e.displayText, '02:00');
  e.reset();
  assert.strictEqual(e.displayText, '01:40');
  assert.strictEqual(e.running, false);
});

test('auto-advance starts next segment', () => {
  const { e, advance } = makeEngine([{ title: 'A', duration: 5, autoAdvance: true }, { title: 'B', duration: 30 }]);
  e.start(); advance(6);
  assert.strictEqual(e.current.title, 'B');
  assert.strictEqual(e.running, true);
});

test('count-up with no target', () => {
  const { e, advance } = makeEngine([{ title: 'A', mode: 'countUp', duration: 0 }]);
  e.start(); advance(75);
  assert.strictEqual(e.displayText, '01:15');
  assert.strictEqual(e.phase, 'normal');
});

test('remote commands', () => {
  const { e } = makeEngine([{ title: 'A' }, { title: 'B' }, { title: 'C' }]);
  assert.ok(e.perform('goto', '3', 'OSC'));
  assert.strictEqual(e.current.title, 'C');
  assert.strictEqual(e.lastRemoteEvent, 'OSC: goto 3');
  e.perform('message', 'Wrap up');
  assert.strictEqual(e.message, 'Wrap up');
  assert.ok(e.messageVisible);
  e.perform('hide');
  assert.ok(!e.messageVisible);
  e.perform('layout', 'videoPIP');
  assert.strictEqual(e.settings.videoLayout, 'videoPIP');
  e.perform('video');
  assert.strictEqual(e.settings.videoLayout, 'timerOnly');
  e.perform('video');
  assert.strictEqual(e.settings.videoLayout, 'videoPIP');
  e.perform('layout', '4');
  assert.strictEqual(e.settings.videoLayout, 'split');
  e.perform('blackout', '1');
  assert.ok(e.blackout);
  assert.ok(!e.perform('nonsense'));
});

test('segment editing and moves', () => {
  const { e } = makeEngine([{ title: 'A' }, { title: 'B' }, { title: 'C' }]);
  const [a, b, c] = e.segments.map((s) => s.id);
  e.moveSegment(c, 0);
  assert.deepStrictEqual(e.segments.map((s) => s.title), ['C', 'A', 'B']);
  e.moveSegment(c, 3);
  assert.deepStrictEqual(e.segments.map((s) => s.title), ['A', 'B', 'C']);
  e.updateSegment(b, { title: 'Bee', duration: 90 });
  assert.strictEqual(e.segments[1].title, 'Bee');
  const d = e.duplicateSegment(a);
  assert.strictEqual(e.segments[1].id, d);
  e.deleteSegment(d);
  assert.strictEqual(e.segments.length, 3);
});

test('rundown files from the Mac app load', () => {
  const s = normaliseSegment({ id: 'X', title: 'T', mode: 'endAtTime', endTime: '2026-10-11T10:30:00Z', duration: 0, yellowAt: 60, redAt: 10, autoAdvance: true });
  assert.strictEqual(s.mode, 'endAtTime');
  assert.strictEqual(s.endTime, '2026-10-11T10:30:00.000Z');
  const { e } = makeEngine();
  e.loadRundown({ segments: [s] });
  assert.strictEqual(e.segments.length, 1);
  assert.throws(() => e.loadRundown({ segments: [] }));
});

test('remote state shape', () => {
  const { e } = makeEngine([{ title: 'A' }]);
  const st = e.remoteState();
  for (const k of ['title', 'time', 'phase', 'running', 'presets', 'segments', 'layouts', 'layout']) assert.ok(k in st, k);
});

// ---- OSC
function oscMessage(address, args = []) {
  const pad = (b) => Buffer.concat([b, Buffer.alloc(4 - (b.length % 4))]);
  const parts = [pad(Buffer.from(address)), pad(Buffer.from(',' + args.map((a) => (typeof a === 'number' ? (Number.isInteger(a) ? 'i' : 'f') : 's')).join('')))];
  for (const a of args) {
    if (typeof a === 'number' && Number.isInteger(a)) { const b = Buffer.alloc(4); b.writeInt32BE(a); parts.push(b); }
    else if (typeof a === 'number') { const b = Buffer.alloc(4); b.writeFloatBE(a); parts.push(b); }
    else parts.push(pad(Buffer.from(a)));
  }
  return Buffer.concat(parts);
}

test('OSC parsing', () => {
  let [m] = parsePacket(oscMessage('/timer/add', [30]));
  assert.deepStrictEqual(m, { address: '/timer/add', args: ['30'] });
  [m] = parsePacket(oscMessage('/timer/message', ['Wrap up']));
  assert.deepStrictEqual(m.args, ['Wrap up']);
  [m] = parsePacket(oscMessage('/timer/next', [1.5]));
  assert.deepStrictEqual(m.args, ['1.5']);
  const bundle = Buffer.concat([Buffer.from('#bundle\0'), Buffer.alloc(8)]);
  const inner = oscMessage('/timer/start');
  const size = Buffer.alloc(4); size.writeInt32BE(inner.length);
  const msgs = parsePacket(Buffer.concat([bundle, size, inner]));
  assert.strictEqual(msgs[0].address, '/timer/start');
});

test('OSC → commands', () => {
  assert.deepStrictEqual(toCommand('/timer/next', ['1']), { command: 'next', argument: null });
  assert.strictEqual(toCommand('/timer/next', ['0']), null); // button release
  assert.deepStrictEqual(toCommand('/timer/add', ['30']), { command: 'add', argument: '30' });
  assert.deepStrictEqual(toCommand('/timer/message/hide', []), { command: 'message-hide', argument: null });
  assert.deepStrictEqual(toCommand('/timer/layout', []), { command: 'layout', argument: null });
});

// ---- updates
test('version compare and asset choice', () => {
  assert.ok(isNewer('2.0.0', '1.0.0'));
  assert.ok(isNewer('1.0.10', '1.0.9'));
  assert.ok(!isNewer('1.0.0', '1.0.0'));
  assert.ok(!isNewer('1.0', '1.0.0'));
  assert.strictEqual(clean('v2.1.0'), '2.1.0');
  const assets = [{ name: 'UniqueAVCountdown-2.0.0-Setup.exe' }, { name: 'UniqueAVCountdown-2.0.0.dmg' }];
  assert.strictEqual(pickAsset(assets, 'darwin').name, 'UniqueAVCountdown-2.0.0.dmg');
  assert.strictEqual(pickAsset(assets, 'win32').name, 'UniqueAVCountdown-2.0.0-Setup.exe');
});

console.log(`${passed} tests passed${process.exitCode ? ', some FAILED' : ''}`);
