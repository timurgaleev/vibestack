// vibe-stealth — always-on anti-detection for the browse daemon + shim.
//
// Applied on EVERY context-creation path so a page can never reach a live
// context un-stealthed. The default (Layer C) is consistency-first: it does NOT
// fake navigator.plugins/languages (modern fingerprinters cross-check those and
// synthetic values flag MORE bot-like). VIBESTACK_STEALTH=extended opts into the
// "actively lies, may break sites" escape hatch (WebGL/plugins/mediaDevices).
//
// Per-install hardware honesty: hardwareConcurrency/deviceMemory come from
// VIBESTACK_HW_CONCURRENCY / VIBESTACK_DEVICE_MEMORY when set, else clamp to 8
// (0/NaN would be a glaring tell). Guardrail, not a guarantee: a JS-only
// toString proxy still has detection surface; it defeats the common depth-3
// [native code] check, which is what routine anti-bot uses.

function readHostProfile() {
  const c = Number(process.env.VIBESTACK_HW_CONCURRENCY)
  const m = Number(process.env.VIBESTACK_DEVICE_MEMORY)
  return {
    hwConcurrency: Number.isFinite(c) && c > 0 ? c : 8,
    deviceMemory: Number.isFinite(m) && m > 0 ? m : 8,
  }
}

function buildStealthScript(hw) {
  return `(() => {
  const patched = new WeakSet();
  const nativeToString = Function.prototype.toString;
  const proxy = new Proxy(nativeToString, {
    apply(target, thisArg, args) {
      if (patched.has(thisArg)) return 'function ' + ((thisArg && thisArg.name) || '') + '() { [native code] }';
      return Reflect.apply(target, thisArg, args);
    },
  });
  Object.defineProperty(Function.prototype, 'toString', { value: proxy, writable: true, configurable: true });
  const mark = (fn, name) => { if (name) { try { Object.defineProperty(fn, 'name', { value: name }); } catch {} } patched.add(fn); return fn; };

  try {
    Object.defineProperty(navigator, 'webdriver', { get: mark(function () { return false; }, 'get webdriver'), configurable: true });
  } catch {}

  try {
    if (!('chrome' in window)) window.chrome = {};
    const chrome = window.chrome;
    if (!chrome.runtime) chrome.runtime = {
      OnInstalledReason: { CHROME_UPDATE: 'chrome_update', INSTALL: 'install', SHARED_MODULE_UPDATE: 'shared_module_update', UPDATE: 'update' },
      OnRestartRequiredReason: { APP_UPDATE: 'app_update', OS_UPDATE: 'os_update', PERIODIC: 'periodic' },
      PlatformArch: { ARM: 'arm', ARM64: 'arm64', MIPS: 'mips', MIPS64: 'mips64', X86_32: 'x86-32', X86_64: 'x86-64' },
      PlatformOs: { ANDROID: 'android', CROS: 'cros', LINUX: 'linux', MAC: 'mac', OPENBSD: 'openbsd', WIN: 'win' },
      connect: mark(function connect() { throw new TypeError('Error in invocation of runtime.connect: No matching signature.'); }, 'connect'),
      sendMessage: mark(function sendMessage() { throw new TypeError('Error in invocation of runtime.sendMessage: No matching signature.'); }, 'sendMessage'),
      id: undefined,
    };
    if (!chrome.app) chrome.app = { isInstalled: false,
      InstallState: { DISABLED: 'disabled', INSTALLED: 'installed', NOT_INSTALLED: 'not_installed' },
      RunningState: { CANNOT_RUN: 'cannot_run', READY_TO_RUN: 'ready_to_run', RUNNING: 'running' } };
    if (typeof chrome.csi !== 'function') chrome.csi = mark(function csi() {
      return { onloadT: Date.now(), pageT: performance.now(), startE: Date.now() - 1000, tran: 15 }; }, 'csi');
    if (typeof chrome.loadTimes !== 'function') chrome.loadTimes = mark(function loadTimes() {
      const t = performance.timing;
      return { requestTime: t.requestStart / 1000, startLoadTime: t.requestStart / 1000, commitLoadTime: t.responseStart / 1000,
        finishDocumentLoadTime: t.domContentLoadedEventEnd / 1000, finishLoadTime: t.loadEventEnd / 1000, firstPaintTime: t.responseEnd / 1000,
        firstPaintAfterLoadTime: 0, navigationType: 'Other', wasFetchedViaSpdy: true, wasNpnNegotiated: true, npnNegotiatedProtocol: 'h2',
        wasAlternateProtocolAvailable: false, connectionInfo: 'h2' }; }, 'loadTimes');
  } catch {}

  try {
    if (typeof Notification !== 'undefined')
      Object.defineProperty(Notification, 'permission', { get: mark(function () { return 'default'; }, 'get permission'), configurable: true });
  } catch {}

  try { Object.defineProperty(navigator, 'hardwareConcurrency', { get: mark(function () { return ${hw.hwConcurrency}; }, 'get hardwareConcurrency'), configurable: true }); } catch {}
  try { Object.defineProperty(navigator, 'deviceMemory', { get: mark(function () { return ${hw.deviceMemory}; }, 'get deviceMemory'), configurable: true }); } catch {}

  try {
    const auto = ['__driver_evaluate','__webdriver_evaluate','__selenium_evaluate','__fxdriver_evaluate',
      '__driver_unwrapped','__webdriver_unwrapped','__selenium_unwrapped','__fxdriver_unwrapped',
      '_Selenium_IDE_Recorder','_selenium','calledSelenium','$chrome_asyncScriptInfo','__$webdriverAsyncExecutor',
      '__webdriverFunc','domAutomation','domAutomationController','__lastWatirAlert','__lastWatirConfirm','__lastWatirPrompt',
      '__webdriver_script_fn','_WEBDRIVER_ELEM_CACHE','callPhantom','_phantom','phantom','__nightmare',
      '__pwInitScripts','__playwright__binding__'];
    for (const k of auto) { try { delete window[k]; } catch {} }
    try { delete document.__webdriver_script_fn; } catch {}
  } catch {}
})();`
}

const AUTOMATION_ARTIFACT_CLEANUP_SCRIPT = `(() => {
  const cleanup = () => { for (const key of Object.keys(window)) {
    if (key.startsWith('cdc_') || key.startsWith('__webdriver')) { try { delete window[key]; } catch (e) { if (!(e instanceof TypeError)) throw e; } } } };
  cleanup(); setTimeout(cleanup, 0);
  const q = window.navigator.permissions && window.navigator.permissions.query;
  if (q) window.navigator.permissions.query = (p) => (p && p.name === 'notifications')
    ? Promise.resolve({ state: 'prompt', onchange: null }) : q.call(window.navigator.permissions, p);
})();`

const EXTENDED_STEALTH_SCRIPT = `(() => {
  try { delete Object.getPrototypeOf(navigator).webdriver; } catch {}
  try {
    const gp = WebGLRenderingContext.prototype.getParameter;
    WebGLRenderingContext.prototype.getParameter = function (p) {
      if (p === 37445) return 'Apple Inc.';
      if (p === 37446) return 'Apple M1 Pro, OpenGL 4.1';
      return gp.call(this, p);
    };
  } catch {}
  try {
    const mk = (name, filename, mimes) => { const p = Object.create(Plugin.prototype);
      Object.defineProperties(p, { name: { get: () => name }, filename: { get: () => filename }, description: { get: () => '' }, length: { get: () => mimes.length } });
      mimes.forEach((m, i) => { p[i] = m; }); p.item = (i) => mimes[i]; p.namedItem = (n) => mimes.find((m) => m.type === n); return p; };
    const mkm = (type) => { const m = Object.create(MimeType.prototype);
      Object.defineProperties(m, { type: { get: () => type }, suffixes: { get: () => 'pdf' }, description: { get: () => '' } }); return m; };
    const plugins = [ mk('PDF Viewer', 'internal-pdf-viewer', [mkm('application/pdf')]),
      mk('Chrome PDF Viewer', 'internal-pdf-viewer', [mkm('application/x-google-chrome-pdf')]) ];
    Object.defineProperty(navigator, 'plugins', { get: () => { const arr = Object.create(PluginArray.prototype);
      Object.defineProperty(arr, 'length', { get: () => plugins.length }); plugins.forEach((p, i) => { arr[i] = p; });
      arr.item = (i) => plugins[i]; arr.namedItem = (n) => plugins.find((p) => p.name === n); arr.refresh = () => {}; return arr; } });
  } catch {}
  try { if (!navigator.mediaDevices) Object.defineProperty(navigator, 'mediaDevices', { get: () => ({ enumerateDevices: () => Promise.resolve([]) }) }); } catch {}
})();`

const extendedEnabled = () => ['extended', '1', 'true'].includes(process.env.VIBESTACK_STEALTH ?? '')

// Args to suppress the AutomationControlled blink feature (protocol-layer tell).
export const STEALTH_LAUNCH_ARGS = ['--disable-blink-features=AutomationControlled']

// Playwright defaults that are themselves automation tells; strip via ignoreDefaultArgs.
export const STEALTH_IGNORE_DEFAULT_ARGS = ['--enable-automation']

// Apply to a fresh BrowserContext. Injection order matters: Layer C first
// (installs the toString proxy before any getter it must cover), then artifact
// cleanup, then extended-only patches when opted in.
export async function applyStealth(context) {
  await context.addInitScript({ content: buildStealthScript(readHostProfile()) })
  await context.addInitScript({ content: AUTOMATION_ARTIFACT_CLEANUP_SCRIPT })
  if (extendedEnabled()) await context.addInitScript({ content: EXTENDED_STEALTH_SCRIPT })
}
