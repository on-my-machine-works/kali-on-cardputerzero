// Shared browser side for the Kali CZ Web Remote Deck.
//
// Frames arrive as an 8-byte little-endian header (x, y, w, h) followed by
// `w * h * 2` bytes of native little-endian 16-bit RGB565 pixels (320x170).
const FLIPPER_HEADER = 8;

class GreyBlitter {
  constructor(ctx, w, h) {
    this.ctx = ctx;
    this.lut = new Uint32Array(65536);
    for (let v = 0; v < 65536; v++) {
      const r = ((((v >> 11) & 0x1f) * 255 + 15) / 31) | 0;
      const g = ((((v >> 5) & 0x3f) * 255 + 31) / 63) | 0;
      const b = (((v & 0x1f) * 255 + 15) / 31) | 0;
      this.lut[v] = 0xff000000 | (b << 16) | (g << 8) | r;
    }
    this.resize(w, h);
  }
  resize(w, h) {
    this.img = this.ctx.createImageData(w, h);
    this.words = new Uint32Array(this.img.data.buffer);
  }
  draw(bytes, x, y, w, h) {
    if (this.img.width !== w || this.img.height !== h) this.resize(w, h);
    const words = this.words;
    const lut = this.lut;
    const n = w * h;
    for (let i = 0, j = 0; i < n; i++, j += 2) {
      words[i] = lut[bytes[j] | (bytes[j + 1] << 8)];
    }
    this.ctx.putImageData(this.img, x, y);
  }
}

const FLIPPER_DEADLINE_MS = 3000;

function flipperStream(onFrame, onStatus) {
  const say = (text, ok) => { if (onStatus) onStatus(text, ok); };
  let ctl = null;
  let heard = 0;
  setInterval(() => {
    if (ctl && performance.now() - heard > FLIPPER_DEADLINE_MS) ctl.abort();
  }, 250);
  (async () => {
    say('connecting');
    for (;;) {
      let live = false;
      ctl = new AbortController();
      heard = performance.now();
      try {
        const res = await fetch('stream', { signal: ctl.signal, cache: 'no-store' });
        if (!res.ok || !res.body) throw new Error('stream ' + res.status);
        const reader = res.body.getReader();
        let buf = new Uint8Array(0);
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          heard = performance.now();
          if (!live) {
            live = true;
            say('connected', true);
          }
          const merged = new Uint8Array(buf.length + value.length);
          merged.set(buf);
          merged.set(value, buf.length);
          buf = merged;
          for (;;) {
            if (buf.length < FLIPPER_HEADER) break;
            const head = new DataView(buf.buffer, buf.byteOffset, FLIPPER_HEADER);
            const x = head.getUint16(0, true), y = head.getUint16(2, true);
            const w = head.getUint16(4, true), h = head.getUint16(6, true);
            const need = FLIPPER_HEADER + w * h * 2;
            if (buf.length < need) break;
            if (w !== 0 && h !== 0) onFrame(buf.subarray(FLIPPER_HEADER, need), x, y, w, h);
            buf = buf.subarray(need);
          }
        }
      } catch (e) {
        // Reconnect automatically after timeout or restart.
      }
      ctl = null;
      say('no signal', false);
      await new Promise(r => setTimeout(r, 1000));
    }
  })();
}

function flipperSend(key, down) {
  fetch('input', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ key, down }),
  }).catch(() => {});
}

function flipperSendRaw(evdev, down, ch) {
  const payload = ch ? { evdev, down, ch } : { evdev, down };
  fetch('input', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  }).catch(() => {});
}

let FLIPPER_DIRECT_KBD = false;
function flipperDirectKbd() { return FLIPPER_DIRECT_KBD; }
function flipperSetDirectKbd(on) { FLIPPER_DIRECT_KBD = Boolean(on); return FLIPPER_DIRECT_KBD; }

// Browser KeyboardEvent.code -> Linux <linux/input-event-codes.h> evdev keycode.
const EVDEV_CODES = {
  Escape: 1, Digit1: 2, Digit2: 3, Digit3: 4, Digit4: 5, Digit5: 6,
  Digit6: 7, Digit7: 8, Digit8: 9, Digit9: 10, Digit0: 11, Minus: 12, Equal: 13,
  Backspace: 14, Tab: 15,
  KeyQ: 16, KeyW: 17, KeyE: 18, KeyR: 19, KeyT: 20, KeyY: 21, KeyU: 22, KeyI: 23, KeyO: 24, KeyP: 25,
  BracketLeft: 26, BracketRight: 27, Enter: 28, NumpadEnter: 96, ControlLeft: 29, ControlRight: 97,
  KeyA: 30, KeyS: 31, KeyD: 32, KeyF: 33, KeyG: 34, KeyH: 35, KeyJ: 36, KeyK: 37, KeyL: 38,
  Semicolon: 39, Quote: 40, Backquote: 41, ShiftLeft: 42, Backslash: 43,
  KeyZ: 44, KeyX: 45, KeyC: 46, KeyV: 47, KeyB: 48, KeyN: 49, KeyM: 50,
  Comma: 51, Period: 52, Slash: 53, ShiftRight: 54, AltLeft: 56, AltRight: 100, Space: 57,
  F1: 59, F2: 60, F3: 61, F4: 62, F5: 63, F6: 64, F7: 65, F8: 66, F9: 67, F10: 68, F11: 87, F12: 88,
  Home: 102, ArrowUp: 103, PageUp: 104, ArrowLeft: 105, ArrowRight: 106,
  End: 107, ArrowDown: 108, PageDown: 109, Insert: 110, Delete: 111,
};

// CardputerZero physical keys ('4'..'8') + arrows + unmodified F/Z/X/C D-pad + Enter/Esc/Tab.
const FLIPPER_KEYS = {
  ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right',
  f: 'up', F: 'up', x: 'down', X: 'down', z: 'left', Z: 'left', c: 'right', C: 'right',
  w: 'up', W: 'up', s: 'down', S: 'down', a: 'left', A: 'left', d: 'right', D: 'right',
  Enter: 'ok', ' ': 'ok', Escape: 'back', Backspace: 'back', q: 'back', Q: 'back', Tab: 'appsw',
  '4': 'esc', '5': 'view', '6': 'power', '7': 'edit', '8': 'run',
  F1: 'esc', F2: 'view', F3: 'power', F4: 'edit', F5: 'run',
  '`': 'ptt', '~': 'ptt',
};

function flipperWireInput(selector) {
  const held = key => document.querySelector(`${selector}[data-k="${key}"]`);
  for (const el of document.querySelectorAll(selector)) {
    const key = el.dataset.k;
    const press = down => {
      el.classList.toggle('down', down);
      flipperSend(key, down);
    };
    el.addEventListener('pointerdown', e => { e.preventDefault(); press(true); });
    el.addEventListener('pointerup', () => press(false));
    el.addEventListener('pointercancel', () => press(false));
    el.addEventListener('pointerleave', () => { if (el.classList.contains('down')) press(false); });
    el.addEventListener('keydown', e => { if (e.key === ' ') { e.preventDefault(); press(true); } });
    el.addEventListener('keyup', e => { if (e.key === ' ') { e.preventDefault(); press(false); } });
  }
  const down = new Set();
  const rawDown = new Set();
  const send = (k, isDown) => {
    if (isDown) down.add(k); else down.delete(k);
    const el = held(k);
    if (el) el.classList.toggle('down', isDown);
    flipperSend(k, isDown);
  };
  const sendRaw = (ev, isDown, ch) => {
    if (isDown) rawDown.add(ev); else rawDown.delete(ev);
    flipperSendRaw(ev, isDown, ch);
  };
  const notControl = e =>
    e.target.tagName !== 'BUTTON' && e.target.tagName !== 'SELECT' && e.target.tagName !== 'INPUT';
  const ours = e => !e.altKey && !e.ctrlKey && !e.metaKey && notControl(e);

  addEventListener('keydown', e => {
    if (!notControl(e) || e.metaKey) return;
    if (FLIPPER_DIRECT_KBD) {
      const ev = EVDEV_CODES[e.code];
      if (ev) {
        e.preventDefault();
        if (!e.repeat) {
          const ch = (!e.ctrlKey && !e.altKey && e.key && e.key.length === 1) ? e.key : '';
          sendRaw(ev, true, ch);
        }
      }
      return;
    }
    if (!ours(e)) return;
    const k = FLIPPER_KEYS[e.key];
    if (k && !e.repeat) {
      e.preventDefault();
      send(k, true);
    } else if (!e.repeat && e.key && e.key.length === 1 && EVDEV_CODES[e.code]) {
      // Unmapped printable characters still forward raw ch/evdev so typing in TextInput/Terminal works seamlessly.
      e.preventDefault();
      sendRaw(EVDEV_CODES[e.code], true, e.key);
    }
  });
  addEventListener('keyup', e => {
    if (!notControl(e)) return;
    const ev = EVDEV_CODES[e.code];
    if (ev && rawDown.has(ev)) {
      e.preventDefault();
      sendRaw(ev, false, '');
      return;
    }
    if (!ours(e)) return;
    const k = FLIPPER_KEYS[e.key];
    if (k) {
      e.preventDefault();
      send(k, false);
    }
  });
  addEventListener('blur', () => {
    for (const k of [...down]) send(k, false);
    for (const ev of [...rawDown]) sendRaw(ev, false, '');
  });
}

function flipperCoalesce(fn) {
  let queued = false;
  return () => {
    if (queued) return;
    queued = true;
    requestAnimationFrame(() => { queued = false; fn(); });
  };
}

function flipperTabs(side) {
  const style = document.createElement('style');
  style.textContent = `
    nav.tabs {
      position: fixed; top: 0; left: 0; right: 0; z-index: 10; height: 48px;
      display: flex; align-items: center; gap: 10px; padding: 0 16px;
      background: #0c1c3a; border-bottom: 1px solid #22385c;
      font: 600 14px system-ui, sans-serif; user-select: none; box-sizing: border-box;
    }
    nav.tabs .kali-pill {
      background: #2c84f5; color: #fff; padding: 3px 8px; border-radius: 4px;
      font: 700 12px monospace; letter-spacing: .06em;
    }
    nav.tabs > a {
      padding: 6px 12px; border-radius: 6px;
      color: #8098b9; text-decoration: none;
    }
    nav.tabs > a:hover { background: rgba(56, 188, 255, .14); color: #ebf3ff; }
    nav.tabs > a.here, nav.tabs > a.here:hover { background: #1c4280; color: #38bcff; border: 1px solid #2c84f5; }
    nav.tabs > .tabs-side {
      margin-left: auto; display: flex; align-items: center; gap: 12px;
      min-width: 0; white-space: nowrap; overflow: hidden;
    }
    body { padding-top: 48px; box-sizing: border-box; }
  `;
  document.head.appendChild(style);

  const nav = document.createElement('nav');
  nav.className = 'tabs';
  const badge = document.createElement('span');
  badge.className = 'kali-pill';
  badge.textContent = 'KALI x CARDPUTERZERO';
  nav.appendChild(badge);
  const apps = /\/apps(\.html)?$/.test(location.pathname);
  for (const [href, label, here] of [['./', 'Live LCD Deck (320x170)', !apps], ['apps', 'App Deck', apps]]) {
    const a = document.createElement('a');
    a.href = href;
    a.textContent = label;
    if (here) a.className = 'here';
    nav.appendChild(a);
  }
  if (side) {
    side.classList.add('tabs-side');
    nav.appendChild(side);
  }
  document.body.prepend(nav);
}
