// Timer engine: rundown, transport, warnings, messages and remote commands.
// Pure Node (no Electron imports) so it can be tested on its own.
const EventEmitter = require('events');
const crypto = require('crypto');

const MODES = ['countdown', 'countUp', 'endAtTime'];
const LAYOUTS = [
  { id: 'timerOnly', label: 'Timer only' },
  { id: 'videoPIP', label: 'Video + timer PIP' },
  { id: 'timerPIP', label: 'Timer + video PIP' },
  { id: 'split', label: 'Side by side' },
  { id: 'videoBar', label: 'Video + timer bar' },
];
const CORNERS = ['topLeft', 'topRight', 'bottomLeft', 'bottomRight'];

// Commands reachable from MIDI notes / CCs, in order from the base note.
const MIDI_MAP = [
  ['toggle', 'Start / Pause'],
  ['start', 'Start'],
  ['pause', 'Pause'],
  ['reset', 'Reset'],
  ['next', 'Next segment'],
  ['prev', 'Previous segment'],
  ['add', '+1 minute'],
  ['sub', '−1 minute'],
  ['flash', 'Flash message'],
  ['message-hide', 'Hide message'],
  ['blackout', 'Toggle blackout'],
  ['layout', 'Next video layout'],
  ['layout-timer', 'Timer only (video off)'],
];

const DEFAULT_SETTINGS = {
  // presenter display
  showTitle: true,
  showClock: true,
  showNext: true,
  showProgress: true,
  clock24h: true,
  fontScale: 1.0,
  // behaviour
  overtimeCountUp: true,
  flashOnOvertime: true,
  soundOnWarning: true,
  soundOnZero: true,
  startOnNext: false,
  checkUpdatesOnLaunch: true,
  // remote
  webEnabled: true,
  webPort: 8080,
  oscEnabled: true,
  oscPort: 8000,
  midiEnabled: true,
  midiChannel: 0, // 0 = omni
  midiBaseNote: 60,
  // messages
  messagePresets: ['Please wrap up', '5 minutes left', '1 minute left', "Time's up", 'Speak up please', 'Slow down'],
  // video
  videoLayout: 'timerOnly',
  pipCorner: 'bottomRight',
  pipSize: 0.34,
  splitRatio: 0.66,
  cropLeft: 0, cropRight: 0, cropTop: 0, cropBottom: 0,
  videoFill: false,
  videoSource: null, // { kind: 'camera'|'screen'|'window', id, name }
  videoFormat: '',   // '' = auto, e.g. "1920x1080@60"
  // output
  presenterDisplayId: null,
};

function uuid() {
  return crypto.randomUUID().toUpperCase();
}

function newSegment(patch = {}) {
  return {
    id: uuid(),
    title: 'New segment',
    speaker: '',
    mode: 'countdown',
    duration: 300,
    endTime: new Date(Date.now() + 3600e3).toISOString(),
    yellowAt: 120,
    redAt: 30,
    autoAdvance: false,
    ...patch,
  };
}

/** Accepts segments from files written by this app or the original Mac app. */
function normaliseSegment(s) {
  const d = newSegment();
  if (!s || typeof s !== 'object') return d;
  const num = (v, def) => (typeof v === 'number' && isFinite(v) ? v : def);
  let endTime = d.endTime;
  if (typeof s.endTime === 'string' && !isNaN(Date.parse(s.endTime))) endTime = new Date(s.endTime).toISOString();
  else if (typeof s.endTime === 'number') endTime = new Date((s.endTime + 978307200) * 1000).toISOString(); // Apple reference date
  return {
    id: typeof s.id === 'string' && s.id ? s.id : d.id,
    title: typeof s.title === 'string' ? s.title : 'Segment',
    speaker: typeof s.speaker === 'string' ? s.speaker : '',
    mode: MODES.includes(s.mode) ? s.mode : 'countdown',
    duration: Math.max(0, num(s.duration, 300)),
    endTime,
    yellowAt: Math.max(0, num(s.yellowAt, 120)),
    redAt: Math.max(0, num(s.redAt, 30)),
    autoAdvance: !!s.autoAdvance,
  };
}

function sampleSegments() {
  return [
    newSegment({ title: 'Welcome & housekeeping', speaker: 'MC', duration: 5 * 60, yellowAt: 60, redAt: 15 }),
    newSegment({ title: 'Keynote', speaker: 'Guest speaker', duration: 20 * 60, yellowAt: 5 * 60, redAt: 60 }),
    newSegment({ title: 'Panel discussion', speaker: 'Panel', duration: 30 * 60, yellowAt: 5 * 60, redAt: 60 }),
    newSegment({ title: 'Q&A', duration: 10 * 60, yellowAt: 2 * 60, redAt: 30 }),
    newSegment({ title: 'Tea break', duration: 15 * 60, yellowAt: 2 * 60, redAt: 30 }),
  ];
}

function formatTime(t, roundUp = false) {
  const total = Math.max(0, roundUp ? Math.ceil(t - 0.001) : Math.floor(t));
  const h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60), s = total % 60;
  const p = (n) => String(n).padStart(2, '0');
  return h > 0 ? `${h}:${p(m)}:${p(s)}` : `${p(m)}:${p(s)}`;
}

function clockString(date, h24) {
  const p = (n) => String(n).padStart(2, '0');
  if (h24) return `${p(date.getHours())}:${p(date.getMinutes())}:${p(date.getSeconds())}`;
  const h = date.getHours() % 12 || 12;
  return `${h}:${p(date.getMinutes())}:${p(date.getSeconds())} ${date.getHours() < 12 ? 'AM' : 'PM'}`;
}

function shortTime(iso) {
  const d = new Date(iso);
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

class TimerEngine extends EventEmitter {
  /**
   * @param {{segments?: object[], settings?: object}} saved
   * @param {() => number} now  injectable clock (ms) for tests
   */
  constructor(saved = {}, now = () => Date.now()) {
    super();
    this.now = now;
    const segs = Array.isArray(saved.segments) ? saved.segments.map(normaliseSegment) : [];
    this.segments = segs.length ? segs : sampleSegments();
    this.settings = { ...DEFAULT_SETTINGS, ...(saved.settings || {}) };
    this.currentId = this.segments[0].id;
    this.running = false;
    this.accumulated = 0;
    this.runStart = null;
    this.adjustment = 0;
    this.fired = { warning: false, critical: false, zero: false };
    this.message = '';
    this.messageVisible = false;
    this.messageFlashing = false;
    this.flashUntil = 0;
    this.blackout = false;
    this.lastRemoteEvent = '—';
    this.lastVideoLayout = this.settings.videoLayout !== 'timerOnly' ? this.settings.videoLayout : 'videoPIP';
    this.configVersion = 1;
  }

  // ---------- config ----------

  configChanged() {
    this.configVersion++;
    this.emit('config');
  }

  getConfig() {
    return {
      version: this.configVersion,
      segments: this.segments,
      settings: this.settings,
      presets: this.cleanPresets(),
      layouts: LAYOUTS,
      corners: CORNERS,
      midiMap: MIDI_MAP.map(([command, label]) => ({ command, label })),
    };
  }

  cleanPresets() {
    const seen = new Set();
    return (this.settings.messagePresets || [])
      .map((p) => String(p).trim())
      .filter((p) => p && !seen.has(p) && seen.add(p));
  }

  updateSettings(patch) {
    if (!patch || typeof patch !== 'object') return;
    for (const [k, v] of Object.entries(patch)) {
      if (k in DEFAULT_SETTINGS) this.settings[k] = v;
    }
    if (patch.videoLayout && patch.videoLayout !== 'timerOnly') this.lastVideoLayout = patch.videoLayout;
    this.configChanged();
  }

  setSegments(list) {
    const segs = (Array.isArray(list) ? list : []).map(normaliseSegment);
    this.segments = segs.length ? segs : [newSegment({ title: 'Segment 1' })];
    if (!this.segments.some((s) => s.id === this.currentId)) {
      this.currentId = this.segments[0].id;
      this.clearTiming();
    }
    this.configChanged();
  }

  updateSegment(id, patch) {
    const i = this.segments.findIndex((s) => s.id === id);
    if (i < 0) return;
    this.segments[i] = normaliseSegment({ ...this.segments[i], ...patch, id });
    this.configChanged();
  }

  addSegment(afterId) {
    const seg = newSegment({ title: `Segment ${this.segments.length + 1}` });
    const i = this.segments.findIndex((s) => s.id === afterId);
    this.segments.splice(i >= 0 ? i + 1 : this.segments.length, 0, seg);
    this.configChanged();
    return seg.id;
  }

  duplicateSegment(id) {
    const i = this.segments.findIndex((s) => s.id === id);
    if (i < 0) return null;
    const copy = { ...this.segments[i], id: uuid(), title: this.segments[i].title + ' (copy)' };
    this.segments.splice(i + 1, 0, copy);
    this.configChanged();
    return copy.id;
  }

  deleteSegment(id) {
    if (this.segments.length < 2) return null;
    const i = this.segments.findIndex((s) => s.id === id);
    if (i < 0) return null;
    this.segments.splice(i, 1);
    if (this.currentId === id) {
      this.currentId = this.segments[Math.min(i, this.segments.length - 1)].id;
      this.clearTiming();
    }
    this.configChanged();
    return this.segments[Math.min(i, this.segments.length - 1)].id;
  }

  moveSegment(id, toIndex) {
    const i = this.segments.findIndex((s) => s.id === id);
    if (i < 0) return;
    const [seg] = this.segments.splice(i, 1);
    const j = Math.max(0, Math.min(this.segments.length, toIndex > i ? toIndex - 1 : toIndex));
    this.segments.splice(j, 0, seg);
    this.configChanged();
  }

  newRundown() {
    this.setSegments([newSegment({ title: 'Segment 1' })]);
    this.goTo(this.segments[0].id);
  }

  loadRundown(file) {
    const segs = file && Array.isArray(file.segments) ? file.segments : null;
    if (!segs || !segs.length) throw new Error('This file has no segments in it.');
    this.setSegments(segs);
    this.goTo(this.segments[0].id);
  }

  rundownFile() {
    return { app: 'Unique AV Countdown', version: 1, segments: this.segments };
  }

  // ---------- derived ----------

  get currentIndex() {
    return this.segments.findIndex((s) => s.id === this.currentId);
  }

  get current() {
    return this.segments[this.currentIndex] || null;
  }

  get nextSegment() {
    const i = this.currentIndex;
    return i >= 0 && i + 1 < this.segments.length ? this.segments[i + 1] : null;
  }

  get elapsed() {
    return this.accumulated + (this.runStart != null ? (this.now() - this.runStart) / 1000 : 0);
  }

  endDate(seg) {
    const t = new Date(seg.endTime);
    const d = new Date(this.now());
    d.setHours(t.getHours(), t.getMinutes(), t.getSeconds(), 0);
    return d.getTime();
  }

  get targetDuration() {
    const s = this.current;
    if (!s) return null;
    if (s.mode === 'countdown') return Math.max(0, s.duration + this.adjustment);
    if (s.mode === 'countUp') return s.duration > 0 ? s.duration + this.adjustment : null;
    return s.duration > 0 ? s.duration : null;
  }

  /** Seconds left (negative = overtime). null for a count-up with no target. */
  get remaining() {
    const s = this.current;
    if (!s) return null;
    if (s.mode === 'countdown') return s.duration + this.adjustment - this.elapsed;
    if (s.mode === 'countUp') return s.duration > 0 ? s.duration + this.adjustment - this.elapsed : null;
    return (this.endDate(s) - this.now()) / 1000 + this.adjustment;
  }

  get displayText() {
    const s = this.current;
    if (!s) return '--:--';
    if (s.mode === 'countUp') return formatTime(this.elapsed);
    const r = this.remaining ?? 0;
    if (r <= 0) return this.settings.overtimeCountUp ? '+' + formatTime(-r) : formatTime(0);
    return formatTime(r, true);
  }

  get phase() {
    const s = this.current;
    if (!s) return 'idle';
    const r = this.remaining;
    if (r == null) return 'normal';
    if (r <= 0) return 'overtime';
    if (r <= s.redAt) return 'critical';
    if (r <= s.yellowAt) return 'warning';
    return 'normal';
  }

  get progress() {
    const s = this.current, t = this.targetDuration;
    if (!s || !t || t <= 0) return 0;
    if (s.mode === 'endAtTime') return Math.min(1, Math.max(0, 1 - (this.remaining ?? 0) / t));
    return Math.min(1, Math.max(0, this.elapsed / t));
  }

  get totalRundown() {
    return this.segments.filter((s) => s.mode !== 'endAtTime').reduce((a, s) => a + s.duration, 0);
  }

  snapshot() {
    const s = this.current;
    const r = this.remaining;
    return {
      configVersion: this.configVersion,
      currentId: this.currentId,
      index: this.currentIndex,
      count: this.segments.length,
      title: s ? s.title : '',
      speaker: s ? s.speaker : '',
      mode: s ? s.mode : 'countdown',
      time: this.displayText,
      phase: this.phase,
      progress: this.progress,
      running: this.running,
      elapsedText: formatTime(this.elapsed),
      remainingText: r == null ? '—' : r >= 0 ? formatTime(r, true) : '+' + formatTime(-r),
      clock: clockString(new Date(this.now()), this.settings.clock24h),
      next: this.nextSegment ? this.nextSegment.title : '',
      message: this.message,
      messageVisible: this.messageVisible,
      messageFlashing: this.messageFlashing,
      blackout: this.blackout,
      layout: this.settings.videoLayout,
      lastRemoteEvent: this.lastRemoteEvent,
      totalText: formatTime(this.totalRundown),
    };
  }

  // ---------- transport ----------

  start() {
    if (!this.current || this.running) return;
    this.runStart = this.now();
    this.running = true;
  }

  pause() {
    if (!this.running) return;
    this.accumulated += (this.now() - this.runStart) / 1000;
    this.runStart = null;
    this.running = false;
  }

  toggle() {
    this.running ? this.pause() : this.start();
  }

  reset() {
    this.clearTiming();
  }

  goTo(id, autostart = false) {
    if (!this.segments.some((s) => s.id === id)) return;
    this.currentId = id;
    this.clearTiming();
    if (autostart) this.start();
  }

  goToIndex(i) {
    if (i >= 0 && i < this.segments.length) this.goTo(this.segments[i].id);
  }

  next() {
    const i = this.currentIndex;
    if (i < 0 || i + 1 >= this.segments.length) return;
    this.goTo(this.segments[i + 1].id, this.running && this.settings.startOnNext);
  }

  previous() {
    const i = this.currentIndex;
    if (i <= 0) return;
    this.goTo(this.segments[i - 1].id, this.running && this.settings.startOnNext);
  }

  addTime(seconds) {
    const s = this.current;
    if (!s) return;
    if (s.mode === 'countUp' && s.duration === 0) {
      this.accumulated = Math.max(0, this.accumulated - seconds);
    } else {
      this.adjustment += seconds;
    }
    this.resetFlags();
  }

  quickTimer(seconds) {
    if (!(seconds > 0)) return;
    const seg = newSegment({
      title: 'Quick timer',
      duration: seconds,
      yellowAt: Math.min(120, seconds * 0.25),
      redAt: Math.min(30, seconds * 0.1),
    });
    this.segments.splice(this.currentIndex + 1, 0, seg);
    this.configChanged();
    this.goTo(seg.id, true);
  }

  clearTiming() {
    this.running = false;
    this.runStart = null;
    this.accumulated = 0;
    this.adjustment = 0;
    this.resetFlags();
  }

  resetFlags() {
    const s = this.current, r = this.remaining;
    if (!s || r == null) {
      this.fired = { warning: false, critical: false, zero: false };
      return;
    }
    this.fired = { warning: r <= s.yellowAt, critical: r <= s.redAt, zero: r <= 0 };
  }

  // ---------- messages ----------

  showMessage(text) {
    const t = String(text ?? '').trim();
    if (!t) return;
    this.message = t;
    this.messageVisible = true;
  }

  hideMessage() {
    this.messageVisible = false;
    this.messageFlashing = false;
    this.flashUntil = 0;
  }

  flashMessage(seconds = 5) {
    if (!this.message) return;
    this.messageVisible = true;
    this.messageFlashing = true;
    this.flashUntil = this.now() + seconds * 1000;
  }

  // ---------- layout ----------

  setLayout(id) {
    if (!LAYOUTS.some((l) => l.id === id)) return;
    if (id !== 'timerOnly') this.lastVideoLayout = id;
    this.settings.videoLayout = id;
    this.configChanged();
  }

  cycleLayout() {
    const i = LAYOUTS.findIndex((l) => l.id === this.settings.videoLayout);
    this.setLayout(LAYOUTS[(i + 1) % LAYOUTS.length].id);
  }

  toggleVideo() {
    this.setLayout(this.settings.videoLayout === 'timerOnly' ? this.lastVideoLayout : 'timerOnly');
  }

  setLayoutNamed(name) {
    const key = String(name).toLowerCase().replace(/\s+/g, '');
    const n = parseInt(key, 10);
    if (String(n) === key && n >= 1 && n <= LAYOUTS.length) return this.setLayout(LAYOUTS[n - 1].id);
    const l = LAYOUTS.find((x) => x.id.toLowerCase() === key);
    if (l) this.setLayout(l.id);
  }

  // ---------- tick ----------

  tick() {
    if (this.flashUntil && this.now() > this.flashUntil) {
      this.flashUntil = 0;
      this.messageFlashing = false;
    }
    const s = this.current, r = this.remaining;
    if (!this.running || !s || r == null) return;
    if (!this.fired.warning && r <= s.yellowAt) {
      this.fired.warning = true;
      if (r > s.redAt && this.settings.soundOnWarning) this.emit('sound', 'warning');
    }
    if (!this.fired.critical && r <= s.redAt) {
      this.fired.critical = true;
      if (r > 0 && this.settings.soundOnWarning) this.emit('sound', 'critical');
    }
    if (!this.fired.zero && r <= 0) {
      this.fired.zero = true;
      if (this.settings.soundOnZero) this.emit('sound', 'zero');
      const i = this.currentIndex;
      if (s.autoAdvance && i + 1 < this.segments.length) this.goTo(this.segments[i + 1].id, true);
    }
  }

  // ---------- remote commands ----------

  /** Runs a command from the UI, web remote, OSC or MIDI. Returns false if unknown. */
  perform(raw, argument, source = '') {
    const c = String(raw || '').toLowerCase().trim();
    const arg = argument == null ? null : String(argument).trim();
    const num = arg !== null && arg !== '' && isFinite(Number(arg)) ? Number(arg) : null;
    const isText = arg !== null && arg !== '' && num === null;

    switch (c) {
      case 'toggle': case 'go': case 'startpause': case 'start-pause': this.toggle(); break;
      case 'start': case 'play': case 'resume': this.start(); break;
      case 'pause': case 'stop': this.pause(); break;
      case 'reset': case 'restart': this.reset(); break;
      case 'next': this.next(); break;
      case 'prev': case 'previous': case 'back': this.previous(); break;
      case 'add': case 'plus': this.addTime(num ?? 60); break;
      case 'sub': case 'subtract': case 'minus': this.addTime(-(num ?? 60)); break;
      case 'goto': case 'cue': case 'segment':
        if (num === null) return false;
        this.goToIndex(Math.round(num) - 1);
        break;
      case 'message': case 'message-show': case 'show-message':
        isText ? this.showMessage(arg) : this.showMessage(this.message);
        break;
      case 'message-hide': case 'message-clear': case 'hide-message': case 'clear': case 'hide':
        this.hideMessage();
        break;
      case 'message-flash': case 'flash':
        if (isText) this.showMessage(arg);
        this.flashMessage();
        break;
      case 'blackout':
        this.blackout = num !== null ? num !== 0 : !this.blackout;
        break;
      case 'quick': this.quickTimer(num ?? 300); break;
      case 'layout':
        arg ? this.setLayoutNamed(arg) : this.cycleLayout();
        break;
      case 'layout-timer': case 'video-off': this.setLayout('timerOnly'); break;
      case 'video': case 'pip': case 'video-toggle':
        if (num !== null) this.setLayout(num !== 0 ? this.lastVideoLayout : 'timerOnly');
        else this.toggleVideo();
        break;
      default:
        return false;
    }
    if (source) this.lastRemoteEvent = `${source}: ${c}${arg ? ' ' + arg : ''}`;
    return true;
  }

  /** State for the phone remote (same shape as the original Mac app). */
  remoteState() {
    const snap = this.snapshot();
    return {
      title: snap.title,
      speaker: snap.speaker,
      time: snap.time,
      phase: snap.phase,
      running: snap.running,
      progress: snap.progress,
      clock: snap.clock,
      message: snap.message,
      messageVisible: snap.messageVisible,
      blackout: snap.blackout,
      index: snap.index,
      next: snap.next,
      presets: this.cleanPresets(),
      layout: this.settings.videoLayout,
      layouts: LAYOUTS,
      segments: this.segments.map((s) => ({
        title: s.title,
        length: s.mode === 'endAtTime' ? 'ends ' + shortTime(s.endTime) : formatTime(s.duration),
        mode: s.mode,
      })),
    };
  }
}

module.exports = {
  TimerEngine, DEFAULT_SETTINGS, LAYOUTS, CORNERS, MIDI_MAP,
  formatTime, normaliseSegment, newSegment, shortTime,
};
