/* Unique AV Countdown — operator window.
   The timer itself runs in the main process; this window shows it, edits the rundown,
   captures video, listens to MIDI and draws the presenter screen. */
(async function () {
  const api = window.uav;
  const $ = (s) => document.querySelector(s);
  const $$ = (s) => Array.from(document.querySelectorAll(s));

  let cfg = await api.getConfig();
  let snap = null;
  let selectedId = cfg.segments[0] && cfg.segments[0].id;
  const info = await api.appInfo();
  const isMac = info.platform === 'darwin';

  const fmt = (t) => {
    t = Math.max(0, Math.floor(t));
    const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60;
    const p = (n) => String(n).padStart(2, '0');
    return h > 0 ? `${h}:${p(m)}:${p(s)}` : `${p(m)}:${p(s)}`;
  };
  const hhmm = (iso) => {
    const d = new Date(iso);
    return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
  };
  const debounce = (fn, ms) => { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; };
  const isTyping = () => {
    const a = document.activeElement;
    return a && (a.tagName === 'INPUT' && !['checkbox', 'range', 'button'].includes(a.type) || a.tagName === 'TEXTAREA' || a.tagName === 'SELECT');
  };

  // ===================================================================== rundown

  const MODE_ICON = { countdown: '⏱', countUp: '⏲', endAtTime: '🕒' };
  let dragId = null;

  function renderRundown() {
    const list = $('#segList');
    list.replaceChildren();
    const currentId = snap ? snap.currentId : null;
    cfg.segments.forEach((seg, i) => {
      const li = document.createElement('li');
      li.dataset.id = seg.id;
      li.draggable = true;
      if (seg.id === selectedId) li.classList.add('sel');
      if (seg.id === currentId) li.classList.add('cur');
      const num = document.createElement('span');
      num.className = 'num';
      num.textContent = seg.id === currentId ? '▶' : String(i + 1);
      const tt = document.createElement('div');
      tt.className = 'tt';
      const t = document.createElement('div');
      t.className = 't';
      t.textContent = seg.title || 'Untitled';
      tt.appendChild(t);
      if (seg.speaker) {
        const s = document.createElement('div');
        s.className = 's';
        s.textContent = seg.speaker;
        tt.appendChild(s);
      }
      const meta = document.createElement('span');
      meta.className = 'meta';
      meta.textContent = `${seg.autoAdvance ? '↪ ' : ''}${MODE_ICON[seg.mode] || ''} ${seg.mode === 'endAtTime' ? hhmm(seg.endTime) : fmt(seg.duration)}`;
      li.append(num, tt, meta);

      li.addEventListener('click', () => { flushEdits(); selectedId = seg.id; renderRundown(); renderEditor(); });
      li.addEventListener('dblclick', () => api.gotoSegment(seg.id, false));
      li.addEventListener('dragstart', (e) => { dragId = seg.id; e.dataTransfer.effectAllowed = 'move'; });
      li.addEventListener('dragend', () => { dragId = null; clearDrop(); });
      li.addEventListener('dragover', (e) => {
        if (!dragId) return;
        e.preventDefault();
        clearDrop();
        const r = li.getBoundingClientRect();
        li.classList.add(e.clientY < r.top + r.height / 2 ? 'drop-before' : 'drop-after');
      });
      li.addEventListener('drop', (e) => {
        e.preventDefault();
        if (!dragId) return;
        const after = li.classList.contains('drop-after');
        clearDrop();
        api.moveSegment(dragId, i + (after ? 1 : 0));
        dragId = null;
      });
      list.appendChild(li);
    });
    const total = cfg.segments.filter((s) => s.mode !== 'endAtTime').reduce((a, s) => a + s.duration, 0);
    $('#rundownMeta').textContent = `${cfg.segments.length} segments · ${fmt(total)}`;
    $('#segDel').disabled = cfg.segments.length < 2;
  }
  function clearDrop() { $$('.seglist li').forEach((li) => li.classList.remove('drop-before', 'drop-after')); }

  function markCurrent() {
    $$('#segList li').forEach((li, i) => {
      const cur = snap && li.dataset.id === snap.currentId;
      li.classList.toggle('cur', cur);
      li.querySelector('.num').textContent = cur ? '▶' : String(i + 1);
    });
  }

  $('#segAdd').onclick = async () => { const id = await api.addSegment(selectedId); if (id) selectedId = id; };
  $('#segDup').onclick = async () => { const id = await api.duplicateSegment(selectedId); if (id) selectedId = id; };
  $('#segDel').onclick = async () => { const id = await api.deleteSegment(selectedId); if (id) selectedId = id; };
  $('#segCue').onclick = () => selectedId && api.gotoSegment(selectedId, false);
  $('#segCueStart').onclick = () => selectedId && api.gotoSegment(selectedId, true);
  $('#quickGo').onclick = () => api.quickTimer(Math.max(1, Number($('#quickMin').value) || 5) * 60);

  // ===================================================================== segment editor

  const selected = () => cfg.segments.find((s) => s.id === selectedId);
  let pending = {};
  let pendingId = null;
  const flushEdits = () => {
    if (pendingId) api.updateSegment(pendingId, pending);
    pending = {};
    pendingId = null;
  };
  const flushSoon = debounce(flushEdits, 250);
  function edit(patch) {
    if (!selectedId) return;
    if (pendingId && pendingId !== selectedId) flushEdits();
    pendingId = selectedId;
    pending = { ...pending, ...patch };
    const seg = selected();
    if (seg) Object.assign(seg, patch); // keep the local copy in step while typing
    flushSoon();
  }

  function buildHMS() {
    $$('.hms').forEach((box) => {
      const key = box.dataset.key;
      box.replaceChildren();
      ['h', 'm', 's'].forEach((unit) => {
        const inp = document.createElement('input');
        inp.type = 'number';
        inp.min = '0';
        inp.dataset.unit = unit;
        inp.addEventListener('input', () => {
          const vals = Object.fromEntries(Array.from(box.querySelectorAll('input')).map((x) => [x.dataset.unit, Math.max(0, Number(x.value) || 0)]));
          edit({ [key]: vals.h * 3600 + vals.m * 60 + vals.s });
        });
        const lbl = document.createElement('span');
        lbl.textContent = unit;
        box.append(inp, lbl);
      });
    });
  }

  function renderEditor() {
    const seg = selected();
    $('#editor').style.visibility = seg ? 'visible' : 'hidden';
    if (!seg) return;
    const setVal = (el, v) => { if (document.activeElement !== el) el.value = v; };
    setVal($('#edTitle'), seg.title);
    setVal($('#edSpeaker'), seg.speaker);
    setVal($('#edMode'), seg.mode);
    $('#edAuto').checked = !!seg.autoAdvance;
    const d = new Date(seg.endTime);
    setVal($('#edEnd'), `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}:${String(d.getSeconds()).padStart(2, '0')}`);
    $$('.hms').forEach((box) => {
      const v = Math.max(0, Math.round(seg[box.dataset.key] || 0));
      const parts = { h: Math.floor(v / 3600), m: Math.floor((v % 3600) / 60), s: v % 60 };
      box.querySelectorAll('input').forEach((inp) => setVal(inp, parts[inp.dataset.unit]));
    });
    $('#rowEnd').hidden = seg.mode !== 'endAtTime';
    $('#durLabel').textContent = seg.mode === 'countdown' ? 'Duration' : seg.mode === 'countUp' ? 'Target (0 = none)' : 'Progress bar window';
  }

  $('#editor').addEventListener('submit', (e) => e.preventDefault());
  $('#edTitle').addEventListener('input', (e) => edit({ title: e.target.value }));
  $('#edSpeaker').addEventListener('input', (e) => edit({ speaker: e.target.value }));
  $('#edMode').addEventListener('change', (e) => { edit({ mode: e.target.value }); renderEditor(); });
  $('#edAuto').addEventListener('change', (e) => edit({ autoAdvance: e.target.checked }));
  $('#edEnd').addEventListener('change', (e) => {
    const [h, m, s] = e.target.value.split(':').map((x) => Number(x) || 0);
    const d = new Date();
    d.setHours(h, m, s || 0, 0);
    edit({ endTime: d.toISOString() });
  });
  buildHMS();

  // ===================================================================== transport

  $('#btnGo').onclick = () => api.cmd('toggle');
  $('#btnPrev').onclick = () => api.cmd('prev');
  $('#btnNext').onclick = () => api.cmd('next');
  $('#btnReset').onclick = () => api.cmd('reset');
  $('#btnBlackout').onclick = () => api.cmd('blackout');
  $$('[data-add]').forEach((b) => { b.onclick = () => api.cmd('add', Number(b.dataset.add)); });

  // ===================================================================== messages

  function renderPresets() {
    const box = $('#presetChips');
    box.replaceChildren();
    for (const p of cfg.presets) {
      const b = document.createElement('button');
      b.textContent = p;
      b.onclick = () => { $('#msgText').value = p; api.cmd('message', p); };
      box.appendChild(b);
    }
  }
  $('#msgShow').onclick = () => api.cmd('message', $('#msgText').value);
  $('#msgFlash').onclick = () => api.cmd('flash', $('#msgText').value || null);
  $('#msgHide').onclick = () => api.cmd('message-hide');
  $('#msgText').addEventListener('keydown', (e) => { if (e.key === 'Enter') { api.cmd('message', e.target.value); e.target.blur(); } });

  // ===================================================================== sounds

  let audio = null;
  function beep(freqs, dur) {
    try {
      audio = audio || new AudioContext();
      let t = audio.currentTime + 0.02;
      for (const f of freqs) {
        const o = audio.createOscillator(), g = audio.createGain();
        o.type = 'sine';
        o.frequency.value = f;
        g.gain.setValueAtTime(0.0001, t);
        g.gain.exponentialRampToValueAtTime(0.35, t + 0.02);
        g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
        o.connect(g).connect(audio.destination);
        o.start(t);
        o.stop(t + dur + 0.05);
        t += dur * 0.85;
      }
    } catch { /* no audio device */ }
  }
  api.on('sound', (kind) => {
    if (kind === 'warning') beep([880], 0.35);
    else if (kind === 'critical') beep([988, 988], 0.22);
    else if (kind === 'zero') beep([784, 988, 1175], 0.3);
  });

  // ===================================================================== video input

  const Video = {
    stream: null,
    source: cfg.settings.videoSource || null,
    status: 'No video input',
    cameras: [],
    desktop: [],
    gen: 0,
    lastFrame: 0,
    width: 0,
    height: 0,

    get active() { return !!this.source; },
    get hasSignal() {
      if (!this.stream) return false;
      const fresh = performance.now() - this.lastFrame < 1500;
      return fresh || (this.source && this.source.kind !== 'camera' && this.width > 0);
    },
    state() {
      return { active: this.active, hasSignal: this.hasSignal, name: this.source ? this.source.name : '' };
    },

    async refresh(ask = false) {
      if (ask) await api.askCamera();
      try {
        const devs = await navigator.mediaDevices.enumerateDevices();
        this.cameras = devs.filter((d) => d.kind === 'videoinput')
          .map((d, i) => ({ kind: 'camera', id: d.deviceId, name: d.label || `Camera ${i + 1}` }));
      } catch { this.cameras = []; }
      // On a Mac, listing screens triggers the Screen Recording prompt, so only do it
      // once allowed or when the user asks (refresh button).
      const access = await api.screenAccess();
      this.desktop = !isMac || access === 'granted' || ask ? await api.desktopSources() : [];
      $('#vidScreenHint').hidden = !isMac || access === 'granted';
      renderSourceSelect();
    },

    find(src) {
      if (!src) return null;
      const pool = src.kind === 'camera' ? this.cameras : this.desktop;
      return pool.find((x) => x.id === src.id)
        || pool.find((x) => x.name === src.name && x.kind === src.kind)
        || null;
    },

    async select(src, persist = true) {
      this.stop();
      this.source = src;
      if (persist) api.updateSettings({ videoSource: src });
      renderVideoControls();
      if (src) await this.start();
      else this.setStatus('No video input');
    },

    async start() {
      const src = this.find(this.source);
      if (!src) {
        this.setStatus(this.source.kind === 'camera'
          ? `Waiting for ${this.source.name} to connect…`
          : `${this.source.name} isn't available. Choose another source or refresh.`);
        return;
      }
      if (src.id !== this.source.id) {
        this.source = { ...this.source, id: src.id };
        api.updateSettings({ videoSource: this.source });
      }
      const gen = ++this.gen;
      this.setStatus(`Opening ${src.name}…`);
      try {
        let constraints;
        if (src.kind === 'camera') {
          await api.askCamera();
          const m = /^(\d+)x(\d+)@(\d+)$/.exec(cfg.settings.videoFormat || '');
          const video = { deviceId: { exact: src.id } };
          if (m) Object.assign(video, { width: { ideal: +m[1] }, height: { ideal: +m[2] }, frameRate: { ideal: +m[3] } });
          else Object.assign(video, { width: { ideal: 1920 }, height: { ideal: 1080 } });
          constraints = { audio: false, video };
        } else {
          constraints = {
            audio: false,
            video: { mandatory: { chromeMediaSource: 'desktop', chromeMediaSourceId: src.id, maxWidth: 3840, maxHeight: 2160, maxFrameRate: 30 } },
          };
        }
        const stream = await navigator.mediaDevices.getUserMedia(constraints);
        if (gen !== this.gen) { stream.getTracks().forEach((t) => t.stop()); return; }
        this.stream = stream;
        const track = stream.getVideoTracks()[0];
        track.addEventListener('ended', () => {
          if (this.stream !== stream) return;
          this.stream = null;
          attachStream();
          this.setStatus(src.kind === 'camera' ? `${src.name} disconnected — waiting for it to come back…` : 'Capture ended — choose the source again');
        });
        attachStream();
        this.setStatus(`Capturing ${src.name}`);
      } catch (e) {
        if (gen !== this.gen) return;
        const name = e && e.name;
        this.setStatus(
          name === 'NotAllowedError' ? (src.kind === 'camera'
            ? 'Camera access is off. Allow it in System Settings › Privacy & Security › Camera.'
            : 'Screen capture is not allowed. Allow it in System Settings › Privacy & Security › Screen Recording, then reopen the app.')
            : name === 'NotReadableError' ? `${src.name} is busy (is another app using it?)`
              : `Couldn't open ${src.name}: ${e.message || name}`);
      }
    },

    stop() {
      this.gen++;
      if (this.stream) this.stream.getTracks().forEach((t) => t.stop());
      this.stream = null;
      this.width = this.height = 0;
      attachStream();
    },

    restart() {
      if (!this.source) return;
      this.stop();
      this.start();
    },

    setStatus(text) {
      this.status = text;
      $('#vidStatus').textContent = text;
      $('#vidStatus').title = text;
    },
  };

  // Watch frames on the preview video to know whether a signal is coming in.
  function watchFrames(video) {
    const onFrame = (_now, meta) => {
      Video.lastFrame = performance.now();
      Video.width = meta.width;
      Video.height = meta.height;
      video.requestVideoFrameCallback(onFrame);
    };
    video.requestVideoFrameCallback(onFrame);
  }

  navigator.mediaDevices.addEventListener('devicechange', async () => {
    await Video.refresh();
    if (Video.source && Video.source.kind === 'camera' && !Video.stream && Video.find(Video.source)) Video.start();
  });

  function renderSourceSelect() {
    const sel = $('#vidSource');
    sel.replaceChildren();
    const opt = (value, text) => { const o = document.createElement('option'); o.value = value; o.textContent = text; return o; };
    sel.appendChild(opt('', 'None'));
    const group = (label, items) => {
      if (!items.length) return;
      const g = document.createElement('optgroup');
      g.label = label;
      items.forEach((s) => g.appendChild(opt(`${s.kind}|${s.id}`, s.name)));
      sel.appendChild(g);
    };
    group('Capture cards & cameras', Video.cameras);
    group('Whole screen', Video.desktop.filter((s) => s.kind === 'screen'));
    group('Window (e.g. PowerPoint Presenter View)', Video.desktop.filter((s) => s.kind === 'window'));
    let value = '';
    if (Video.source) {
      const found = Video.find(Video.source);
      value = found ? `${found.kind}|${found.id}` : `missing|${Video.source.id}`;
      if (!found) sel.appendChild(opt(value, `${Video.source.name} (not available)`));
    }
    sel.value = value;
  }

  $('#vidSource').addEventListener('change', (e) => {
    const v = e.target.value;
    if (!v) return Video.select(null);
    if (v.startsWith('missing|')) return;
    const [kind, ...rest] = v.split('|');
    const id = rest.join('|');
    const pool = kind === 'camera' ? Video.cameras : Video.desktop;
    const src = pool.find((s) => s.id === id && s.kind === kind);
    if (src) Video.select({ kind: src.kind, id: src.id, name: src.name });
  });
  $('#vidRefresh').onclick = () => Video.refresh(true);
  $('#vidRestart').onclick = () => Video.restart();
  $('#vidAllow').onclick = () => api.openScreenSettings();
  $('#vidFormat').addEventListener('change', async (e) => {
    await api.updateSettings({ videoFormat: e.target.value });
    if (Video.source && Video.source.kind === 'camera') Video.restart();
  });
  $('#vidLayout').addEventListener('change', (e) => api.cmd('layout', e.target.value));
  $('#vidCorner').addEventListener('change', (e) => api.updateSettings({ pipCorner: e.target.value }));
  $('#vidPipSize').addEventListener('input', (e) => api.updateSettings({ pipSize: Number(e.target.value) }));
  $('#vidSplit').addEventListener('input', (e) => api.updateSettings({ splitRatio: Number(e.target.value) }));
  $('#vidCropBtn').onclick = () => { $('#cropPanel').hidden = !$('#cropPanel').hidden; };
  $('#vidFill').addEventListener('change', (e) => api.updateSettings({ videoFill: e.target.checked }));
  $$('[data-crop]').forEach((r) => r.addEventListener('input', () => api.updateSettings({ [r.dataset.crop]: Number(r.value) })));
  $$('[data-cropset]').forEach((b) => {
    b.onclick = () => {
      const [l, r, t, bt] = b.dataset.cropset.split(',').map(Number);
      api.updateSettings({ cropLeft: l, cropRight: r, cropTop: t, cropBottom: bt });
    };
  });

  function renderVideoControls() {
    const s = cfg.settings;
    const layoutSel = $('#vidLayout');
    if (!layoutSel.options.length) {
      for (const l of cfg.layouts) {
        const o = document.createElement('option');
        o.value = l.id;
        o.textContent = l.label;
        layoutSel.appendChild(o);
      }
    }
    const setVal = (el, v) => { if (document.activeElement !== el) el.value = v; };
    setVal(layoutSel, s.videoLayout);
    setVal($('#vidCorner'), s.pipCorner);
    setVal($('#vidPipSize'), s.pipSize);
    setVal($('#vidSplit'), s.splitRatio);
    setVal($('#vidFormat'), s.videoFormat || '');
    $('#vidFill').checked = !!s.videoFill;
    $$('[data-crop]').forEach((r) => {
      setVal(r, s[r.dataset.crop] || 0);
      r.nextElementSibling.textContent = `${Math.round((s[r.dataset.crop] || 0) * 100)}%`;
    });
    const cropped = ['cropLeft', 'cropRight', 'cropTop', 'cropBottom'].some((k) => s[k] > 0);
    $('#vidCropInfo').textContent = cropped ? 'cropped' : '';
    $('#vidPipRow').hidden = !(s.videoLayout === 'videoPIP' || s.videoLayout === 'timerPIP');
    $('#vidSplitRow').hidden = s.videoLayout !== 'split';
    $('#vidFormatRow').hidden = !(Video.source && Video.source.kind === 'camera');
    $('#vidNoSourceHint').hidden = !!Video.source || s.videoLayout === 'timerOnly';
  }

  // ===================================================================== presenter screen

  const preview = new PresenterRender($('#preview'));
  watchFrames(preview.video);
  let presenterWin = null;
  let presenterRender = null;

  function attachStream() {
    preview.setStream(Video.stream);
    if (presenterRender) presenterRender.setStream(Video.stream);
  }

  // Called by presenter.html when it has loaded.
  window.presenterReady = async (win) => {
    presenterWin = win;
    const root = win.document.getElementById('root');
    if (!root) return;
    if (presenterRender) presenterRender.destroy();
    presenterRender = new PresenterRender(root);
    presenterRender.setStream(Video.stream);
    const r = await api.placePresenter();
    win.document.body.classList.toggle('windowed', !!r.windowed);
    updatePresenterButton();
    draw();
  };

  function togglePresenter() {
    if (presenterWin && !presenterWin.closed) {
      presenterWin.close();
      return;
    }
    presenterRender = null;
    presenterWin = window.open('app://ui/presenter.html', 'presenter');
    updatePresenterButton();
  }

  function presenterOpen() { return !!(presenterWin && !presenterWin.closed && presenterRender); }

  function updatePresenterButton() {
    const open = presenterOpen();
    const b = $('#btnPresenter');
    b.textContent = open ? 'Hide Presenter Screen' : 'Show Presenter Screen';
    b.classList.toggle('live', open);
    $('#liveBadge').textContent = open ? '● LIVE' : 'PREVIEW';
    $('#liveBadge').classList.toggle('live', open);
  }

  api.on('presenter:closed', () => {
    presenterWin = null;
    presenterRender = null;
    updatePresenterButton();
  });
  $('#btnPresenter').onclick = togglePresenter;

  async function loadDisplays() {
    const { displays, selected } = await api.getDisplays();
    const sel = $('#displaySelect');
    sel.replaceChildren();
    for (const d of displays) {
      const o = document.createElement('option');
      o.value = String(d.id);
      o.textContent = d.name;
      sel.appendChild(o);
    }
    sel.value = String(selected);
  }
  $('#displaySelect').addEventListener('change', async (e) => {
    const r = await api.setPresenterDisplay(Number(e.target.value));
    if (presenterOpen()) presenterWin.document.body.classList.toggle('windowed', !!r.windowed);
  });
  api.on('displays:changed', async () => {
    await loadDisplays();
    if (presenterOpen()) {
      const r = await api.placePresenter();
      presenterWin.document.body.classList.toggle('windowed', !!r.windowed);
    }
  });

  // ===================================================================== MIDI

  const midi = { status: 'Off', access: null, last: '' };
  async function initMidi() {
    if (!navigator.requestMIDIAccess) { midi.status = 'Not available on this computer'; return; }
    try {
      midi.access = await navigator.requestMIDIAccess({ sysex: false });
      midi.access.onstatechange = attachMidi;
      attachMidi();
    } catch (e) {
      midi.status = `Unavailable (${e.message || e.name})`;
    }
  }
  function attachMidi() {
    const inputs = Array.from(midi.access.inputs.values());
    inputs.forEach((input) => { input.onmidimessage = onMidi; });
    midi.status = inputs.length
      ? `Listening to ${inputs.length} MIDI source${inputs.length === 1 ? '' : 's'}`
      : 'Listening — no MIDI devices found';
  }
  function onMidi(e) {
    const s = cfg.settings;
    if (!s.midiEnabled) return;
    const [st, d1, d2] = e.data;
    const type = st & 0xf0;
    const ch = (st & 0x0f) + 1;
    if (s.midiChannel && s.midiChannel !== ch) return;
    if ((type === 0x90 && d2 > 0) || (type === 0xb0 && d2 >= 64)) {
      const kind = type === 0x90 ? 'note' : 'CC';
      const m = cfg.midiMap[d1 - s.midiBaseNote];
      if (m) api.cmd(m.command, null, `MIDI ${kind} ${d1}`);
      else midi.last = `MIDI: ${kind} ${d1} ch${ch} (unmapped)`;
    } else if (type === 0xc0) {
      api.cmd('goto', d1 + 1, `MIDI PC ${d1}`);
    }
  }

  // ===================================================================== remote info

  async function refreshRemote() {
    const r = await api.remoteInfo();
    $('#webStatus').textContent = r.web;
    $('#oscStatus').textContent = r.osc;
    $('#midiStatus').textContent = cfg.settings.midiEnabled ? midi.status : 'Off';
    for (const box of [$('#webUrls'), $('#settingsUrls')]) {
      box.replaceChildren();
      for (const u of r.urls) {
        const d = document.createElement('div');
        d.textContent = u;
        box.appendChild(d);
      }
    }
  }
  setInterval(refreshRemote, 2000);

  // ===================================================================== settings dialog

  function openSettings() {
    $('#settings').hidden = false;
    renderSettings();
    api.updateStatus().then((t) => { $('#updateStatus').textContent = t; });
  }
  function closeSettings() { $('#settings').hidden = true; }
  $('#btnSettings').onclick = openSettings;
  $('#settingsClose').onclick = closeSettings;
  $('#settings').addEventListener('mousedown', (e) => { if (e.target.id === 'settings') closeSettings(); });
  $$('#tabs button').forEach((b) => {
    b.onclick = () => {
      $$('#tabs button').forEach((x) => x.classList.toggle('on', x === b));
      $$('.tab').forEach((t) => { t.hidden = t.dataset.tab !== b.dataset.tab; });
    };
  });

  const midiCh = $('#midiChannel');
  midiCh.appendChild(Object.assign(document.createElement('option'), { value: '0', textContent: 'Omni (all)' }));
  for (let i = 1; i <= 16; i++) midiCh.appendChild(Object.assign(document.createElement('option'), { value: String(i), textContent: `Channel ${i}` }));

  const noteName = (n) => `${['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'][((n % 12) + 12) % 12]}${Math.floor(n / 12) - 2}`;

  $$('[data-set]').forEach((el) => {
    const key = el.dataset.set;
    const evt = el.type === 'checkbox' || el.tagName === 'SELECT' ? 'change' : el.type === 'range' ? 'input' : 'change';
    el.addEventListener(evt, () => {
      let v = el.type === 'checkbox' ? el.checked : el.value;
      if (el.type === 'number' || el.type === 'range' || el.tagName === 'SELECT') v = Number(v);
      if (key.endsWith('Port') && !(v >= 1024 && v <= 65535)) return;
      api.updateSettings({ [key]: v });
    });
  });
  $('#presetsText').addEventListener('input', debounce((e) => api.updateSettings({ messagePresets: e.target.value.split('\n') }), 300));
  $('#btnCheckUpdates').onclick = async () => {
    $('#updateStatus').textContent = 'Checking…';
    await api.checkUpdates();
    $('#updateStatus').textContent = await api.updateStatus();
  };

  function renderSettings() {
    const s = cfg.settings;
    $$('[data-set]').forEach((el) => {
      if (document.activeElement === el) return;
      const v = s[el.dataset.set];
      if (el.type === 'checkbox') el.checked = !!v;
      else el.value = String(v);
    });
    $('#fontScaleOut').textContent = `${Math.round(s.fontScale * 100)}%`;
    if (document.activeElement !== $('#presetsText')) $('#presetsText').value = (s.messagePresets || []).join('\n');
    $('#midiNoteName').textContent = noteName(s.midiBaseNote);
    $('#midiMapList').textContent = cfg.midiMap.map((m, i) => {
      const n = s.midiBaseNote + i;
      return `Note/CC ${n} (${noteName(n)})  →  ${m.label}`;
    }).join('\n') + '\nProgram Change N  →  cue segment N+1';
    $('#appVersion').textContent = info.version;
  }

  // ===================================================================== buttons & menu

  $('#btnOpen').onclick = () => api.openRundown();
  $('#btnSave').onclick = () => api.saveRundown();
  api.on('menu', (what) => {
    if (what === 'toggle-presenter') togglePresenter();
    else if (what === 'settings') openSettings();
  });

  // ===================================================================== keyboard

  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      if (!$('#settings').hidden) closeSettings();
      else if (!$('#cropPanel').hidden) $('#cropPanel').hidden = true;
      else if (isTyping()) document.activeElement.blur();
      return;
    }
    if (isTyping() || !$('#settings').hidden) return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    const k = e.key;
    const map = {
      ' ': ['toggle'], Enter: ['toggle'], ArrowRight: ['next'], ArrowLeft: ['prev'],
      ArrowUp: ['add', 60], ArrowDown: ['sub', 60], '+': ['add', 60], '=': ['add', 60], '-': ['sub', 60], _: ['sub', 60],
      ']': ['add', 10], '[': ['sub', 10], r: ['reset'], R: ['reset'], f: ['flash'], F: ['flash'],
      h: ['message-hide'], H: ['message-hide'], b: ['blackout'], B: ['blackout'],
      v: ['video'], V: ['video'], l: ['layout'], L: ['layout'],
    };
    if (k === 'd' || k === 'D') { togglePresenter(); e.preventDefault(); return; }
    const c = map[k];
    if (!c) return;
    e.preventDefault();
    api.cmd(c[0], c[1]);
  });

  // ===================================================================== live updates

  function draw() {
    if (!snap) return;
    const v = Video.state();
    preview.update(snap, cfg, v);
    if (presenterRender) {
      if (presenterWin && presenterWin.closed) { presenterRender = null; updatePresenterButton(); }
      else presenterRender.update(snap, cfg, v);
    }
  }

  let lastCurrent = null;
  api.on('tick', (s) => {
    snap = s;
    const go = $('#btnGo');
    go.textContent = s.running ? '❚❚ Pause' : '▶ Start';
    go.classList.toggle('running', s.running);
    $('#btnBlackout').classList.toggle('on', s.blackout);
    $('#stElapsed').textContent = s.elapsedText;
    $('#stRemaining').textContent = s.remainingText;
    $('#stSegment').textContent = s.index >= 0 ? `${s.index + 1} of ${s.count}` : '—';
    $('#stNext').textContent = s.next || '—';
    $('#stClock').textContent = s.clock;
    $('#lastRemote').textContent = midi.last && s.lastRemoteEvent === '—' ? midi.last : s.lastRemoteEvent;
    $('#msgDot').classList.toggle('on', s.messageVisible);
    $('#msgStatus').textContent = s.messageVisible ? `On screen: ${s.message}` : 'No message on screen';
    const live = Video.hasSignal;
    $('#vidDot').className = 'dot ' + (live ? 'ok' : Video.source ? 'wait' : '');
    $('#vidRes').textContent = live && Video.width ? `${Video.width}×${Video.height}` : '';
    if (s.currentId !== lastCurrent) { lastCurrent = s.currentId; markCurrent(); }
    draw();
  });

  api.on('config', (c) => {
    const layoutChanged = c.settings.videoLayout !== cfg.settings.videoLayout;
    cfg = c;
    if (!cfg.segments.some((s) => s.id === selectedId)) selectedId = cfg.segments[0] && cfg.segments[0].id;
    renderRundown();
    renderEditor();
    renderPresets();
    renderVideoControls();
    if (!$('#settings').hidden) renderSettings();
    if (layoutChanged) draw();
  });

  // ===================================================================== start

  renderRundown();
  renderEditor();
  renderPresets();
  renderVideoControls();
  updatePresenterButton();
  loadDisplays();
  initMidi().then(refreshRemote);
  await Video.refresh();
  if (Video.source) Video.start();
})();
