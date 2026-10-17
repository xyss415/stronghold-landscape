// One-tap landscape: the game is designed for a landscape screen, and the rotate hint (public/index.html,
// css/theme.css) asks a portrait phone to turn the device — impossible in a browser with no auto-rotate that also
// refuses screen.orientation.lock() (iPhone Safari, most in-app WebViews). This module turns the PICTURE instead:
// <html class="sp-force-landscape"> (css/devices.css) rotates the whole body 90° with a CSS transform and sizes it to
// the app's own frame, read from the real visual viewport (--app-w = the visible HEIGHT, --app-h = the visible WIDTH).
//
// A rotated body desyncs every DOM coordinate API from the app's own (rotated) layout frame, so four prototypes are
// shadowed while the class is on — the app itself needs no change:
//   1. Element.prototype.getBoundingClientRect → the rect in the app frame (a canvas rect, the HUD, a tooltip anchor)
//   2. window capture listeners → clientX/clientY (and the x/y, pageX/pageY aliases) of pointer / mouse / wheel events
//      are rewritten into the app frame before any handler sees them (ui/device.js's long press too)
//   3. Document.prototype.elementFromPoint / elementsFromPoint → an app-frame point is converted back to the viewport
//   4. window.innerWidth / innerHeight and visualViewport.width / height / offsetTop / offsetLeft → the app frame size
// so render/app.js (canvasPoint, tileScreen, pieceScreenRect), render/drag.js, ui/facingWheel.js, ui/fallbackField.js,
// the tooltips (ui/components.js), the detail panel (screens/game.js panelFrame) and the field host sizing all keep
// working in the app's own frame. Everything is restored the moment the rotation is dropped.
//
// The stored preference (sp.pref.landscape) is only a WISH: `turned = wish && the device is a touch screen whose SCREEN
// is not physically in landscape`, so turning the phone by hand (or Android's orientation lock succeeding inside
// fullscreen) drops the rotation by itself and the wish waits for the next portrait session. `oneTap()` — the hint's
// 「一键横屏」 button — first asks for fullscreen + a native orientation lock inside the tap's own gesture, waits for the
// viewport to settle, and only then forces the picture: otherwise it would turn and immediately turn back.

import { useEffect, useState } from '../../vendor/hooks.module.js';
import { html, Icon } from './components.js';
import { detectFeatures, fullscreen, screenLandscape } from './device.js';
import { loadPref, savePref } from '../store.js';
import { onLangChange, t } from '../../../shared/i18n.js';

/** Kept on <html> while the picture is turned (css/devices.css). */
export const LANDSCAPE_CLASS = 'sp-force-landscape';

/** How long to let a native orientation lock settle before turning the picture by hand (ms). */
const LOCK_SETTLE_MS = 260;

/** The events whose client coordinates are rewritten into the app frame (capture, window). */
const COORD_EVENTS = [
  'pointerdown', 'pointermove', 'pointerup', 'pointercancel', 'pointerover', 'pointerout', 'pointerenter', 'pointerleave',
  'mousedown', 'mousemove', 'mouseup', 'click', 'dblclick', 'auxclick', 'contextmenu', 'wheel',
];

// ---- state ---------------------------------------------------------------------------------------------------------

let wish = !!loadPref('landscape', false);   // the stored preference (sp.pref.landscape)
let turned = false;                          // the picture is rotated right now
let frame = { w: 1, h: 1 };                  // the app frame: w = the visible HEIGHT, h = the visible WIDTH
let lastKey = null;                          // `${wish}|${turned}` of the last notification
const listeners = new Set();
let boot = null;                             // the installLandscape disposer

function notify() {
  for (const fn of [...listeners]) {
    try { fn(); } catch (err) { /** @type {any} */ (globalThis).console?.error('[landscape] listener failed', err); }
  }
}

// ---- the true (unrotated) viewport size ----------------------------------------------------------------------------

/** Descriptors of the properties this module shadows, captured before it shadows them (obj → prop → descriptor). */
const rawDesc = new Map();

function rememberRaw(obj, prop) {
  if (!obj) return;
  let m = rawDesc.get(obj);
  if (!m) { m = new Map(); rawDesc.set(obj, m); }
  if (m.has(prop)) return;
  let o = obj;
  let d = null;
  while (o && !(d = Object.getOwnPropertyDescriptor(o, prop))) o = Object.getPrototypeOf(o);
  m.set(prop, d || null);
}

/** The property's real value even while it is shadowed (falls back to a plain read before anything was shadowed). */
function rawValue(obj, prop, fallback = 0) {
  if (!obj) return fallback;
  const d = rawDesc.get(obj)?.get(prop);
  let v;
  if (d && typeof d.get === 'function') { try { v = d.get.call(obj); } catch { v = fallback; } }
  else if (d && 'value' in d) v = d.value;
  else { try { v = obj[prop]; } catch { v = fallback; } }
  return Number.isFinite(v) ? v : fallback;
}

/** The real visible size, never the app frame (visualViewport first: it excludes the mobile toolbars). */
function rawSize(win = globalThis) {
  const vv = win.visualViewport;
  const w = rawValue(vv, 'width', 0);
  const h = rawValue(vv, 'height', 0);
  if (w > 0 && h > 0) return { w, h };
  return { w: rawValue(win, 'innerWidth', 0), h: rawValue(win, 'innerHeight', 0) };
}

/** The app frame of a portrait phone: its width is the screen's visible height, its height the visible width. */
function measure(win = globalThis) {
  const raw = rawSize(win);
  const vw = Math.max(1, Math.round(raw.w || 1));
  const vh = Math.max(1, Math.round(raw.h || 1));
  frame = { w: vh, h: vw };
  return frame;
}

/** App frame ↔ viewport: (lx, ly) → (h − ly, lx) for `translateX(app-h) rotate(90deg)` with `transform-origin: 0 0`. */
const viewportFromLocal = (lx, ly) => ({ x: frame.h - ly, y: lx });
const localFromViewport = (vx, vy) => ({ x: vy, y: frame.h - vx });

// ---- the four shadowed APIs (installed only while turned) -----------------------------------------------------------

let shadows = null;   // { win, offs, records }

function shadow(obj, prop, getter) {
  if (!obj) return null;
  const own = Object.getOwnPropertyDescriptor(obj, prop);
  try {
    Object.defineProperty(obj, prop, { configurable: true, enumerable: true, get: getter });
  } catch { return null; }
  return { obj, prop, own };
}

/** Replace a prototype method, remembering its own descriptor so the uninstall restores it exactly. */
function patchMethod(records, obj, prop, make) {
  const orig = obj?.[prop];
  if (typeof orig !== 'function') return null;
  const own = Object.getOwnPropertyDescriptor(obj, prop);
  obj[prop] = make(orig);
  records.push({ obj, prop, own });
  return orig;
}

/** Rewrite a trusted event's client coordinates into the app frame (the browser keeps hit-testing the real point). */
function rewriteEvent(e) {
  if (!e || e.isTrusted === false) return;   // our own synthetic events (ui/device.js) already carry app-frame points
  const vx = e.clientX;
  const vy = e.clientY;
  if (typeof vx !== 'number' || typeof vy !== 'number' || !Number.isFinite(vx) || !Number.isFinite(vy)) return;
  const { x, y } = localFromViewport(vx, vy);
  for (const [prop, value] of [['clientX', x], ['clientY', y], ['x', x], ['y', y], ['pageX', x], ['pageY', y]]) {
    try { Object.defineProperty(e, prop, { configurable: true, enumerable: true, get: () => value }); } catch { /* ignore */ }
  }
}

function installShadows(win = globalThis) {
  if (shadows && shadows.win === win) return;
  if (shadows) uninstallShadows();
  const doc = win.document;
  const ElementProto = win.Element?.prototype;
  const DocProto = win.Document?.prototype;
  const vv = win.visualViewport;

  // remember the true descriptors before shadowing anything (measure() reads them while turned)
  for (const [obj, prop] of [[vv, 'width'], [vv, 'height'], [vv, 'offsetTop'], [vv, 'offsetLeft'],
    [win, 'innerWidth'], [win, 'innerHeight']]) rememberRaw(obj, prop);

  const records = [];
  const offs = [];

  // 1. rects: the viewport rect → the app frame
  patchMethod(records, ElementProto, 'getBoundingClientRect', (orig) => function getBoundingClientRect() {
    const r = orig.call(this);
    const x = r.top;
    const y = frame.h - r.right;
    const w = r.height;
    const h = r.width;
    try { return new win.DOMRect(x, y, w, h); } catch { /* ignore */ }
    return { x, y, width: w, height: h, top: y, left: x, right: x + w, bottom: y + h, toJSON() { return this; } };
  });

  // 2. events: the browser's client coordinates → the app frame, before any handler (window capture runs first)
  for (const type of COORD_EVENTS) {
    const fn = (e) => rewriteEvent(e);
    win.addEventListener(type, fn, { capture: true, passive: true });
    offs.push(() => win.removeEventListener(type, fn, { capture: true }));
  }

  // 3. elementFromPoint: an app-frame point → a viewport point
  patchMethod(records, DocProto, 'elementFromPoint', (orig) => function elementFromPoint(x, y) {
    const v = viewportFromLocal(x, y);
    return orig.call(this, v.x, v.y);
  });
  patchMethod(records, DocProto, 'elementsFromPoint', (orig) => function elementsFromPoint(x, y) {
    const v = viewportFromLocal(x, y);
    return orig.call(this, v.x, v.y);
  });

  // 4. the sizes the app reads
  for (const rec of [
    shadow(win, 'innerWidth', () => frame.w),
    shadow(win, 'innerHeight', () => frame.h),
    shadow(vv, 'width', () => frame.w),
    shadow(vv, 'height', () => frame.h),
    shadow(vv, 'offsetTop', () => 0),
    shadow(vv, 'offsetLeft', () => 0),
  ]) if (rec) records.push(rec);

  shadows = { win, offs, records };
}

function uninstallShadows() {
  if (!shadows) return;
  const { offs, records } = shadows;
  shadows = null;
  for (const off of offs.splice(0)) { try { off(); } catch { /* ignore */ } }
  for (const { obj, prop, own } of records) {
    try {
      if (own) Object.defineProperty(obj, prop, own);
      else delete obj[prop];
    } catch { /* ignore */ }
  }
}

// ---- applying the wish ---------------------------------------------------------------------------------------------

function setVars(win = globalThis) {
  const style = win.document?.documentElement?.style;
  if (!style) return;
  style.setProperty('--app-w', `${frame.w}px`);
  style.setProperty('--app-h', `${frame.h}px`);
}

function clearVars(win = globalThis) {
  const style = win.document?.documentElement?.style;
  style?.removeProperty('--app-w');
  style?.removeProperty('--app-h');
}

/** Turn the picture on or off for the current wish / device and notify only on a real change. */
function apply(win = globalThis) {
  const root = win.document?.documentElement;
  if (!root) return;
  const on = wish && screenLandscape(win) !== true && landscape.available(win);
  if (on) {
    measure(win);
    setVars(win);
    installShadows(win);
    root.classList.add(LANDSCAPE_CLASS);
  } else {
    root.classList.remove(LANDSCAPE_CLASS);
    uninstallShadows();
    clearVars(win);
  }
  turned = on;
  const key = `${wish}|${turned}`;
  if (key !== lastKey) { lastKey = key; notify(); }
}

// ---- public API ----------------------------------------------------------------------------------------------------

/**
 * One-tap landscape: the persisted wish, whether the picture is turned right now, and the controls for both.
 * `available` = a touch screen (a narrow desktop window keeps the game: rotating a mouse-driven layout would only
 * confuse).
 */
export const landscape = {
  /** Whether the one-tap rotation is offered at all (a coarse pointer / touch screen). O(1) once ui/device.js has put
   * its sp-coarse class on <html>; the feature detection stays as the pre-boot / test fallback. */
  available(win = globalThis) {
    if (win.document?.documentElement?.classList?.contains('sp-coarse')) return true;
    return !!detectFeatures(win).coarse;
  },
  /** The stored wish (`true` = turn the picture whenever the SCREEN is in portrait). */
  enabled() { return wish; },
  /** Whether the picture is rotated right now. */
  active() { return turned; },
  /** The app frame while turned: { w: visible height, h: visible width } (px). */
  frame() { return { ...frame }; },
  /**
   * Store the wish and apply it at once (the class + the shadowed APIs follow).
   * @param {boolean} on
   * @returns {boolean} the wish
   */
  set(on) {
    const next = !!on;
    if (next !== wish) { wish = next; savePref('landscape', wish); }
    apply();
    return wish;
  },
  /** Flip the wish (the HUD / title button). */
  toggle() { return this.set(!wish); },
  /**
   * The hint's 「一键横屏」: fullscreen + a native orientation lock inside the tap's own gesture first, then the picture
   * only if the screen did not turn itself (see the module header).
   * @returns {Promise<boolean>} whether the game now has a landscape screen / picture
   */
  async oneTap(win = globalThis) {
    if (!landscape.available(win)) return false;
    // The settle promise is the deadline: a browser that neither resolves nor rejects screen.orientation.lock() (or a
    // requestFullscreen that never settles) must not hold the button hostage.
    const settle = new Promise((resolve) => setTimeout(resolve, LOCK_SETTLE_MS));
    const enter = (async () => {
      try { if (!fullscreen.active(win)) await fullscreen.enter(win); } catch { /* fullscreen refused: the picture alone is enough */ }
    })();
    await Promise.race([enter, settle]);
    await settle;
    if (screenLandscape(win) === true) return true;   // the device (or Android's lock) turned by itself
    return landscape.set(true);
  },
  /** Observe wish / turned changes (useLandscape, the hint buttons). */
  subscribe(fn) { listeners.add(fn); return () => { listeners.delete(fn); }; },
};

/** Preact hook: the one-tap landscape state, re-rendering on every change. */
export function useLandscape() {
  const [snap, setSnap] = useState(() => snapshot());
  useEffect(() => landscape.subscribe(() => setSnap(snapshot())), []);
  return snap;
}

function snapshot(win = globalThis) {
  return { available: landscape.available(win), enabled: wish, active: turned };
}

/**
 * The HUD / title button: turns the picture by hand (`landscape.toggle`), hidden where the one-tap rotation makes no
 * sense. The rotate hint's own 「一键横屏」 button goes through `landscape.oneTap` instead (fullscreen + lock + picture).
 * @param {{ class?: string }} props
 */
export function RotateButton({ class: cls = '' }) {
  const st = useLandscape();
  if (!st.available) return null;
  const label = st.active ? t('取消强制横屏') : t('一键横屏');
  return html`<button type="button" class=${`fsbtn tapx ${cls}`} aria-label=${label} title=${label}
      aria-pressed=${st.active ? 'true' : 'false'} data-testid="rotate-btn" onClick=${() => landscape.toggle()}>
    <${Icon} name="rotate" />
  </button>`;
}

/**
 * Localize the static parts of the rotate hint (index.html) — the same pattern as ui/device.js's
 * updateRotateHintPwaI18n. A missing translation falls back to the Chinese msgid (shared/i18n.js).
 */
export function updateRotateHintI18n(doc = globalThis.document) {
  const turn = doc?.getElementById?.('rotate-hint-turn');
  if (turn) turn.textContent = t('一键横屏');
  const fs = doc?.getElementById?.('rotate-hint-fs');
  if (fs) fs.textContent = t('全屏');
}

// ---- boot-time installation ----------------------------------------------------------------------------------------

/**
 * Install the one-tap landscape on this page (idempotent): the stored wish is applied before the first render (no
 * flash), every viewport change re-measures / re-applies, and the hint's buttons are wired. Returns a disposer (tests).
 * @param {any} [win]
 */
export function installLandscape(win = globalThis) {
  if (boot) return boot;
  const doc = win.document;
  if (!doc?.documentElement) return () => {};
  const offs = [];
  const on = (target, ev, fn, opts) => { if (!target?.addEventListener) return; target.addEventListener(ev, fn, opts); offs.push(() => target.removeEventListener(ev, fn, opts)); };

  apply(win);   // a stored wish turns the picture before the first render

  const reapply = () => apply(win);
  on(win, 'resize', reapply, { passive: true });
  on(win.visualViewport, 'resize', reapply, { passive: true });
  on(win, 'orientationchange', reapply);
  on(win.screen?.orientation, 'change', reapply);

  updateRotateHintI18n(doc);
  offs.push(onLangChange(() => updateRotateHintI18n(doc)));
  const turnBtn = doc.getElementById('rotate-hint-turn');
  if (turnBtn) on(turnBtn, 'click', () => { landscape.oneTap(win); });
  const fsBtn = doc.getElementById('rotate-hint-fs');
  if (fsBtn) {
    fsBtn.hidden = !fullscreen.supported(win);
    on(fsBtn, 'click', () => { fullscreen.enter(win); });
  }

  boot = () => {
    for (const off of offs.splice(0)) { try { off(); } catch { /* ignore */ } }
    uninstallShadows();
    boot = null;
  };
  return boot;
}
