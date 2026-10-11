// Draws the presenter screen (timer, video PIP layouts, message) into a container.
// The operator window uses one instance for its preview and another, created in the
// presenter window's document, for the live screen.
(function () {
  const NO_SIGNAL_ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M16 10.5 21 7v10l-5-3.5"/><rect x="3" y="6" width="13" height="12" rx="2"/><path d="M2 2l20 20"/></svg>';

  function fitScale(text) {
    // Estimated width in em of the digits at full size; keeps long times (1:02:05, +12:00) on screen.
    let em = 0;
    for (const ch of text) em += ch === ':' ? 0.32 : 0.62;
    return Math.min(1, 2.9 / Math.max(em, 0.1));
  }

  class PresenterRender {
    constructor(container) {
      this.doc = container.ownerDocument;
      this.root = this.el('div', 'pv');
      container.appendChild(this.root);
      this.video = this.doc.createElement('video');
      this.video.muted = true;
      this.video.autoplay = true;
      this.video.playsInline = true;
      this.video.disablePictureInPicture = true;
      this.key = null;
      this.timers = [];
      this.bars = [];
      this.videoBox = null;
      this.cache = new Map();
      this.videoCss = '';
    }

    el(tag, cls, parent) {
      const e = this.doc.createElement(tag);
      if (cls) e.className = cls;
      if (parent) parent.appendChild(e);
      return e;
    }

    setStream(stream) {
      if (this.video.srcObject === stream) return;
      this.video.srcObject = stream || null;
      if (stream) this.video.play().catch(() => {});
    }

    destroy() {
      this.video.srcObject = null;
      this.root.remove();
    }

    // ---- building blocks

    timerPanel(cls) {
      const root = this.el('div', 'tp ' + (cls || ''));
      const inner = this.el('div', 'tp-in', root);
      const head = this.el('div', 'tp-head', inner);
      const tt = this.el('div', 'tp-tt', head);
      const t = {
        root,
        title: this.el('div', 'tp-title', tt),
        speaker: this.el('div', 'tp-speaker', tt),
        clock: this.el('div', 'tp-clock', head),
        digits: this.el('div', 'tp-digits', inner),
      };
      const foot = this.el('div', 'tp-foot', inner);
      const next = this.el('div', 'tp-next', foot);
      this.el('span', 'lbl', next).textContent = 'NEXT';
      t.next = this.el('span', '', next);
      t.nextWrap = next;
      const bar = this.el('div', 'bar', foot);
      t.bar = this.el('i', '', bar);
      this.timers.push(t);
      return root;
    }

    timerBar() {
      const root = this.el('div', 'tb');
      const bar = this.el('div', 'bar', root);
      const inner = this.el('div', 'tb-in', root);
      const left = this.el('div', 'tb-side left', inner);
      const b = {
        root,
        bar: this.el('i', '', bar),
        title: this.el('div', 'tb-title', left),
        speaker: this.el('div', 'tb-speaker', left),
        digits: this.el('div', 'tb-digits', inner),
      };
      const right = this.el('div', 'tb-side right', inner);
      b.clock = this.el('div', 'tb-clock', right);
      b.next = this.el('div', 'tb-next', right);
      this.bars.push(b);
      return root;
    }

    videoBlock(cls) {
      const root = this.el('div', 'vb ' + (cls || ''));
      root.appendChild(this.video);
      const ns = this.el('div', 'vb-ns', root);
      ns.innerHTML = NO_SIGNAL_ICON;
      const b = this.el('b', '', ns);
      const s = this.el('span', '', ns);
      this.videoBox = { root, label: b, name: s };
      if (this.video.srcObject) this.video.play().catch(() => {});
      return root;
    }

    build(layout, corner) {
      this.root.replaceChildren();
      this.timers = [];
      this.bars = [];
      this.videoBox = null;
      this.cache.clear();
      this.videoCss = '';
      const r = this.root;
      switch (layout) {
        case 'videoPIP':
          r.appendChild(this.videoBlock('full'));
          r.appendChild(this.timerPanel(`compact pipbox ${corner}`));
          break;
        case 'timerPIP':
          r.appendChild(this.timerPanel(`full reserve-${corner}`));
          r.appendChild(this.videoBlock(`pipbox ${corner}`));
          break;
        case 'split': {
          const row = this.el('div', 'row', r);
          row.appendChild(this.videoBlock());
          row.appendChild(this.timerPanel());
          break;
        }
        case 'videoBar': {
          const col = this.el('div', 'col', r);
          col.appendChild(this.videoBlock());
          col.appendChild(this.timerBar());
          break;
        }
        default:
          r.appendChild(this.timerPanel('full'));
      }
      this.message = this.el('div', 'msg', r);
    }

    // ---- per-tick update

    set(node, prop, value) {
      let m = this.cache.get(node);
      if (!m) { m = {}; this.cache.set(node, m); }
      if (m[prop] === value) return;
      m[prop] = value;
      if (prop === 'text') node.textContent = value;
      else if (prop === 'width') node.style.width = value;
      else node.style.setProperty(prop, value);
    }

    /**
     * @param snap   engine snapshot (from the main process)
     * @param cfg    config ({settings, ...})
     * @param video  {active, hasSignal, name}
     */
    update(snap, cfg, video) {
      if (!snap || !cfg) return;
      const s = cfg.settings;
      const layout = video.active ? s.videoLayout : 'timerOnly';
      const key = `${layout}|${s.pipCorner}`;
      if (key !== this.key) {
        this.key = key;
        this.build(layout, s.pipCorner);
      }

      const r = this.root;
      const blink = Math.floor(Date.now() / 500) % 2 === 0;
      const flash = snap.phase === 'overtime' && s.flashOnOvertime && snap.running && blink;
      if (r.dataset.phase !== snap.phase) r.dataset.phase = snap.phase;
      r.classList.toggle('blackout', !!snap.blackout);
      r.classList.toggle('hide-title', !s.showTitle);
      r.classList.toggle('hide-clock', !s.showClock);
      r.classList.toggle('hide-next', !s.showNext);
      r.classList.toggle('hide-progress', !s.showProgress);
      this.set(r, '--fs', String(s.fontScale || 1));
      this.set(r, '--pip', String(Math.min(0.6, Math.max(0.15, s.pipSize || 0.34))));
      this.set(r, '--split', String(Math.min(0.85, Math.max(0.3, s.splitRatio || 0.66))));

      const pct = `${Math.round((snap.progress || 0) * 1000) / 10}%`;
      for (const t of this.timers) {
        t.root.classList.toggle('flash', flash);
        this.set(t.title, 'text', snap.title);
        this.set(t.speaker, 'text', snap.speaker);
        this.set(t.clock, 'text', snap.clock);
        this.set(t.digits, 'text', snap.time);
        this.set(t.digits, '--fit', String(fitScale(snap.time)));
        this.set(t.next, 'text', snap.next);
        t.nextWrap.style.visibility = snap.next ? 'visible' : 'hidden';
        this.set(t.bar, 'width', pct);
        if (layout === 'timerPIP') this.set(t.digits, '--ds', '0.72');
      }
      for (const b of this.bars) {
        b.root.classList.toggle('flash', flash);
        this.set(b.title, 'text', snap.title);
        this.set(b.speaker, 'text', snap.speaker);
        this.set(b.clock, 'text', snap.clock);
        this.set(b.digits, 'text', snap.time);
        this.set(b.next, 'text', snap.next ? `Next: ${snap.next}` : '');
        this.set(b.bar, 'width', pct);
      }

      if (this.videoBox) {
        const vb = this.videoBox;
        vb.root.classList.toggle('nosignal', !video.hasSignal);
        this.set(vb.label, 'text', video.active ? 'No signal' : 'No video input');
        this.set(vb.name, 'text', video.name || '');
        this.fitVideo(vb.root, s);
      }

      // message banner: top when the bottom is busy
      const m = this.message;
      const visible = !!(snap.messageVisible && snap.message);
      const bottomBusy = layout === 'videoBar'
        || ((layout === 'videoPIP' || layout === 'timerPIP') && /^bottom/.test(s.pipCorner));
      m.classList.toggle('show', visible);
      m.classList.toggle('top', bottomBusy);
      m.classList.toggle('off', visible && snap.messageFlashing && !blink);
      this.set(m, 'text', snap.message || '');
    }

    /** Sizes the video inside its box, applying crop and fit/fill. */
    fitVideo(box, s) {
      const v = this.video;
      const bw = box.clientWidth, bh = box.clientHeight, w = v.videoWidth, h = v.videoHeight;
      let css;
      if (!w || !h || !bw || !bh) {
        css = `object-fit:${s.videoFill ? 'cover' : 'contain'}`;
      } else {
        const c = (x) => Math.min(0.5, Math.max(0, Number(x) || 0));
        let l = c(s.cropLeft), rr = c(s.cropRight), t = c(s.cropTop), b = c(s.cropBottom);
        if (l + rr > 0.9) { const k = 0.9 / (l + rr); l *= k; rr *= k; }
        if (t + b > 0.9) { const k = 0.9 / (t + b); t *= k; b *= k; }
        const vw = w * (1 - l - rr), vh = h * (1 - t - b);
        const k = s.videoFill ? Math.max(bw / vw, bh / vh) : Math.min(bw / vw, bh / vh);
        const x = (bw - vw * k) / 2 - l * w * k;
        const y = (bh - vh * k) / 2 - t * h * k;
        css = `inset:auto;left:${x.toFixed(1)}px;top:${y.toFixed(1)}px;width:${(w * k).toFixed(1)}px;height:${(h * k).toFixed(1)}px;object-fit:fill;max-width:none;max-height:none`;
      }
      if (css !== this.videoCss) {
        this.videoCss = css;
        v.style.cssText = css;
      }
    }
  }

  window.PresenterRender = PresenterRender;
})();
