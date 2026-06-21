// vibe-browse — stateless Playwright-backed `$B` shim (2a).
//
// Each invocation is independent: a small context file records the current URL
// and viewport; every capture verb launches Chromium, navigates to that URL,
// captures, and closes. Read-only verbs (screenshot/js/css/console/network/
// perf/text/is) derive everything from a fresh load, so no live browser needs
// to persist between calls. Interaction verbs that require cross-call element
// refs (snapshot -i, click, fill, …) are intentionally NOT supported here and
// report `NOT_SUPPORTED:<verb>` — the consuming skill skips that pass cleanly.
import { mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { resolve, join } from 'node:path'
import { pathToFileURL } from 'node:url'
import net from 'node:net'

// Playwright lives in a self-contained install (the launcher points
// VIBE_BROWSE_DEP_DIR at it). ESM does not honor NODE_PATH for bare specifiers,
// so resolve it to an absolute path and import lazily — verbs that need no
// browser (status, url, viewport, NOT_SUPPORTED) then work without it.
const getChromium = async () => {
  const candidates = [
    process.env.VIBE_BROWSE_DEP_DIR && join(process.env.VIBE_BROWSE_DEP_DIR, 'node_modules/playwright/index.js'),
    join(process.cwd(), 'node_modules/playwright/index.js'),
  ].filter(Boolean)
  for (const c of candidates) {
    if (!existsSync(c)) continue
    const mod = await import(pathToFileURL(c).href)
    return mod.chromium ?? mod.default?.chromium
  }
  die('BROWSE_NOT_AVAILABLE: Playwright not installed', 2)
}

const CTX_DIR = process.env.VIBE_BROWSE_CTX_DIR ?? join(tmpdir(), 'vibe-browse')
const CTX_FILE = join(CTX_DIR, 'ctx.json')
const NAV_TIMEOUT = Number(process.env.VIBE_BROWSE_TIMEOUT ?? 30000)
const ACTION_TIMEOUT = Number(process.env.VIBE_BROWSE_ACTION_TIMEOUT ?? 10000)

const VIEWPORTS = {
  mobile: { width: 390, height: 844 },
  tablet: { width: 820, height: 1180 },
  desktop: { width: 1440, height: 900 },
}

const UNSUPPORTED = new Set([
  'snapshot', 'click', 'fill', 'hover', 'focus', 'upload', 'dialog',
  'dialog-accept', 'inspect', 'load-html', 'connect', 'disconnect', 'cleanup',
  'cookie-import', 'cookie-import-browser', 'cookies', 'pair-agent', 'tunnel',
  'handoff', 'resume', 'diff', 'download', 'prettyscreenshot',
])

// ── context ────────────────────────────────────────────────────────────────
const readCtx = () => {
  if (!existsSync(CTX_FILE)) return {}
  try { return JSON.parse(readFileSync(CTX_FILE, 'utf8')) } catch { return {} }
}
const writeCtx = (ctx) => {
  mkdirSync(CTX_DIR, { recursive: true })
  writeFileSync(CTX_FILE, JSON.stringify(ctx, null, 2))
}

// Resolve file:// shorthands (./ cwd-relative, ~ home-relative).
const resolveUrl = (raw) => {
  if (raw.startsWith('file://~')) return 'file://' + join(homedir(), raw.slice(8))
  if (raw.startsWith('file://./')) return 'file://' + resolve(process.cwd(), raw.slice(9))
  return raw
}

const die = (msg, code = 1) => { console.error(msg); process.exit(code) }
const requireUrl = (ctx) => {
  if (!ctx.url) die('No URL in context — run `goto <url>` first.', 1)
  return ctx.url
}

// ── shared browser load ──────────────────────────────────────────────────────
// Launches Chromium, navigates to the context URL, returns the live page plus
// collected console errors / failed requests. Caller must close `browser`.
const load = async (ctx, viewport) => {
  const chromium = await getChromium()
  const browser = await chromium.launch()
  const context = await browser.newContext({
    viewport: viewport ?? ctx.viewport ?? VIEWPORTS.desktop,
    deviceScaleFactor: 1,
  })
  const page = await context.newPage()
  const errors = []
  const failed = []
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text().slice(0, 300)) })
  page.on('pageerror', (e) => errors.push('pageerror: ' + String(e).slice(0, 300)))
  page.on('requestfailed', (r) =>
    failed.push(`${r.method()} ${r.url().slice(0, 160)} — ${r.failure()?.errorText ?? 'failed'}`))
  let status = 0
  try {
    const resp = await page.goto(requireUrl(ctx), { waitUntil: 'networkidle', timeout: NAV_TIMEOUT })
    status = resp?.status() ?? 0
  } catch (e) {
    errors.push('goto: ' + String(e).slice(0, 200))
  }
  await page.waitForTimeout(300)
  return { browser, page, errors, failed, status }
}

// ── verbs ────────────────────────────────────────────────────────────────────
const verbs = {
  status() {
    // Stateless shim is never CDP-attached; report a launched-mode line so the
    // consuming skill's `grep "Mode: cdp"` check resolves to non-CDP.
    console.log('Mode: launched (vibe-browse stateless shim)')
  },

  async goto([raw]) {
    if (!raw) die('usage: goto <url>')
    const url = resolveUrl(raw)
    const ctx = { ...readCtx(), url }
    writeCtx(ctx)
    const { browser, status, errors } = await load(ctx)
    await browser.close()
    console.log(JSON.stringify({ url, status, errors }, null, 2))
    if (status && status >= 400) process.exit(1)
  },

  url() { console.log(readCtx().url ?? '') },

  viewport([spec]) {
    const m = /^(\d+)x(\d+)$/.exec(spec ?? '')
    if (!m) die('usage: viewport <WxH>  e.g. 375x812')
    writeCtx({ ...readCtx(), viewport: { width: +m[1], height: +m[2] } })
    console.log(`viewport set ${m[1]}x${m[2]}`)
  },

  async screenshot([path]) {
    if (!path) die('usage: screenshot <path>')
    const ctx = readCtx()
    const { browser, page, status, errors } = await load(ctx)
    mkdirSync(join(path, '..'), { recursive: true })
    await page.screenshot({ path, fullPage: true })
    await browser.close()
    console.log(JSON.stringify({ screenshot: path, status, errors }, null, 2))
  },

  async responsive([prefix]) {
    if (!prefix) die('usage: responsive <path-prefix>')
    const ctx = readCtx()
    const out = []
    for (const [name, vp] of Object.entries(VIEWPORTS)) {
      const { browser, page, status } = await load(ctx, vp)
      const file = `${prefix}-${name}.png`
      mkdirSync(join(file, '..'), { recursive: true })
      await page.screenshot({ path: file, fullPage: name === 'desktop' })
      await browser.close()
      out.push({ viewport: name, file, status })
    }
    console.log(JSON.stringify(out, null, 2))
  },

  async console_([flag]) {
    const ctx = readCtx()
    const { browser, errors } = await load(ctx)
    await browser.close()
    console.log(JSON.stringify({ errors }, null, 2))
    if (flag === '--errors' && errors.length) process.exit(1)
  },

  async network() {
    const ctx = readCtx()
    const { browser, failed } = await load(ctx)
    await browser.close()
    console.log(JSON.stringify({ failedRequests: failed }, null, 2))
    if (failed.length) process.exit(1)
  },

  async perf() {
    const ctx = readCtx()
    const { browser, page } = await load(ctx)
    const metrics = await page.evaluate(() => {
      const nav = performance.getEntriesByType('navigation')[0] ?? {}
      const paint = performance.getEntriesByType('paint')
      const fcp = paint.find((p) => p.name === 'first-contentful-paint')
      return {
        ttfb: Math.round(nav.responseStart ?? 0),
        domContentLoaded: Math.round(nav.domContentLoadedEventEnd ?? 0),
        load: Math.round(nav.loadEventEnd ?? 0),
        firstContentfulPaint: fcp ? Math.round(fcp.startTime) : null,
      }
    })
    await browser.close()
    console.log(JSON.stringify(metrics, null, 2))
  },

  async js([expr]) {
    if (!expr) die('usage: js "<expression>"')
    const ctx = readCtx()
    const { browser, page } = await load(ctx)
    let result
    try { result = await page.evaluate(`(() => (${expr}))()`) }
    catch (e) { await browser.close(); die('eval error: ' + String(e).slice(0, 200)) }
    await browser.close()
    console.log(typeof result === 'string' ? result : JSON.stringify(result))
  },

  async css([selector, prop]) {
    if (!selector || !prop) die('usage: css <selector> <property>')
    const ctx = readCtx()
    const { browser, page } = await load(ctx)
    const value = await page.evaluate(
      ([s, p]) => { const el = document.querySelector(s); return el ? getComputedStyle(el)[p] : null },
      [selector, prop])
    await browser.close()
    console.log(value ?? '')
  },

  async text() {
    const ctx = readCtx()
    const { browser, page } = await load(ctx)
    const body = await page.evaluate(() => document.body?.innerText ?? '')
    await browser.close()
    console.log(body.slice(0, 5000))
  },

  async is([state, selector]) {
    if (!state || !selector) die('usage: is <visible|enabled|disabled|checked|editable|focused> <selector>')
    const ctx = readCtx()
    const { browser, page } = await load(ctx)
    const loc = page.locator(selector).first()
    let ok = false
    try {
      switch (state) {
        case 'visible': ok = await loc.isVisible(); break
        case 'enabled': ok = await loc.isEnabled(); break
        case 'disabled': ok = await loc.isDisabled(); break
        case 'checked': ok = await loc.isChecked(); break
        case 'editable': ok = await loc.isEditable(); break
        case 'focused': ok = await page.evaluate((s) => document.activeElement === document.querySelector(s), selector); break
        default: await browser.close(); die(`unknown state: ${state}`)
      }
    } catch { ok = false }
    await browser.close()
    console.log(String(ok))
    process.exit(ok ? 0 : 1)
  },

  // Stateful interaction: run a sequence of steps on ONE live page. Each arg is
  // one step ("goto <url>", "fill <sel> <value...>", "click <sel>", ...). The
  // page persists across steps, so form-fill → submit → screenshot works in a
  // single call without cross-call element refs (which would need a daemon).
  async chain(steps) {
    if (!steps.length) {
      die('usage: chain "goto <url>" "fill <sel> <val>" "click <sel>" "screenshot <path>" …\n' +
          '  step verbs: goto click fill type press hover check uncheck select wait screenshot text eval is')
    }
    const ctx = readCtx()
    const chromium = await getChromium()
    const headed = process.env.VIBE_BROWSE_HEADED === '1'
    const browser = await chromium.launch({ headless: !headed })
    const context = await browser.newContext({ viewport: ctx.viewport ?? VIEWPORTS.desktop, deviceScaleFactor: 1 })
    const page = await context.newPage()
    page.on('dialog', (d) => d.accept().catch(() => {}))
    const log = []
    let failed = false
    for (const raw of steps) {
      const parts = String(raw).trim().split(/\s+/)
      const v = parts[0]
      const a = parts.slice(1)
      const sel = a[0]
      const loc = () => page.locator(sel).first()
      try {
        switch (v) {
          case 'goto': { const r = await page.goto(resolveUrl(a[0]), { waitUntil: 'networkidle', timeout: NAV_TIMEOUT }); log.push({ step: raw, status: r?.status() ?? null }); if ((r?.status() ?? 0) >= 400) throw new Error('HTTP ' + r.status()); break }
          case 'click': await loc().click({ timeout: ACTION_TIMEOUT }); log.push({ step: raw, ok: true }); break
          case 'fill': await loc().fill(a.slice(1).join(' '), { timeout: ACTION_TIMEOUT }); log.push({ step: raw, ok: true }); break
          case 'type': await loc().pressSequentially(a.slice(1).join(' '), { timeout: ACTION_TIMEOUT }); log.push({ step: raw, ok: true }); break
          case 'press': await page.keyboard.press(a[0]); log.push({ step: raw, ok: true }); break
          case 'hover': await loc().hover({ timeout: ACTION_TIMEOUT }); log.push({ step: raw, ok: true }); break
          case 'check': await loc().check({ timeout: ACTION_TIMEOUT }); log.push({ step: raw, ok: true }); break
          case 'uncheck': await loc().uncheck({ timeout: ACTION_TIMEOUT }); log.push({ step: raw, ok: true }); break
          case 'select': await loc().selectOption(a.slice(1).join(' ')); log.push({ step: raw, ok: true }); break
          case 'wait': { const w = a[0]; if (/^\d+$/.test(w)) await page.waitForTimeout(+w); else await page.locator(w).first().waitFor({ timeout: ACTION_TIMEOUT }); log.push({ step: raw, ok: true }); break }
          case 'screenshot': { mkdirSync(join(a[0], '..'), { recursive: true }); await page.screenshot({ path: a[0], fullPage: true }); log.push({ step: raw, screenshot: a[0] }); break }
          case 'text': { const t = await page.evaluate(() => document.body?.innerText ?? ''); log.push({ step: raw, text: t.slice(0, 2000) }); break }
          case 'eval': { const r = await page.evaluate(`(() => (${a.join(' ')}))()`); log.push({ step: raw, result: typeof r === 'string' ? r : JSON.stringify(r) }); break }
          case 'is': { const st = a[0]; const l = page.locator(a[1]).first(); let ok = false; try { ok = st === 'visible' ? await l.isVisible() : st === 'enabled' ? await l.isEnabled() : st === 'checked' ? await l.isChecked() : st === 'editable' ? await l.isEditable() : false } catch {} log.push({ step: raw, [st]: ok }); if (!ok) throw new Error(`not ${st}: ${a[1]}`); break }
          default: throw new Error(`unknown step verb: ${v}`)
        }
      } catch (e) {
        log.push({ step: raw, error: String(e?.message ?? e).slice(0, 200) })
        failed = true
        break
      }
    }
    await browser.close()
    console.log(JSON.stringify({ chain: log }, null, 2))
    if (failed) process.exit(1)
  },
}

// ── daemon client ────────────────────────────────────────────────────────────
// When the persistent daemon is running, stateful verbs (and the verbs that act
// on the live page) proxy to it over its unix socket. With no daemon, the
// interaction-only verbs stay NOT_SUPPORTED and the rest run statelessly.
const DAEMON_SOCK = process.env.VIBE_BROWSE_DAEMON_SOCK ?? join(tmpdir(), 'vibe-browse', 'daemon.sock')
const DAEMON_INTERACTION = new Set(['snapshot', 'click', 'fill', 'type', 'hover', 'check', 'uncheck', 'select', 'press', 'back', 'forward', 'reload', 'cookies'])
const DAEMON_HANDLED = new Set([...DAEMON_INTERACTION, 'goto', 'screenshot', 'text', 'url', 'eval'])

const daemonAlive = () => new Promise((res) => {
  const s = net.connect(DAEMON_SOCK)
  s.on('error', () => res(false))
  s.on('connect', () => { s.end(); res(true) })
})
const proxyToDaemon = (verb, args) => new Promise((res) => {
  const s = net.connect(DAEMON_SOCK)
  let buf = ''
  s.on('error', () => res(null))
  s.on('connect', () => s.write(JSON.stringify({ verb, args }) + '\n'))
  s.on('data', (d) => { buf += d.toString(); const nl = buf.indexOf('\n'); if (nl >= 0) { s.end(); try { res(JSON.parse(buf.slice(0, nl))) } catch { res(null) } } })
})

// ── dispatch ─────────────────────────────────────────────────────────────────
const [, , verb, ...args] = process.argv
if (!verb) die('usage: vibe-browse <verb> [args]   (verbs: goto screenshot responsive console network perf js css is text url viewport status chain | daemon daemon-status daemon-stop snapshot click fill type hover check select press)', 2)

if (verb === 'daemon-status') {
  console.log((await daemonAlive()) ? 'Mode: daemon (running)' : 'Mode: launched (no daemon)')
  process.exit(0)
}
if (verb === 'daemon-stop') {
  const r = await proxyToDaemon('__stop', [])
  console.log(r?.stopped ? 'daemon stopped' : 'no daemon running')
  process.exit(0)
}
if (DAEMON_HANDLED.has(verb) && (await daemonAlive())) {
  const r = await proxyToDaemon(verb, args)
  console.log(JSON.stringify(r, null, 2))
  process.exit(r?.ok ? 0 : 1)
}
if (DAEMON_INTERACTION.has(verb)) die(`NOT_SUPPORTED:${verb}`, 2)  // no daemon → start one: vibe-browse daemon &

if (UNSUPPORTED.has(verb)) die(`NOT_SUPPORTED:${verb}`, 2)

const handler = verbs[verb === 'console' ? 'console_' : verb]
if (!handler) die(`NOT_SUPPORTED:${verb}`, 2)

try {
  await handler(args)
} catch (e) {
  die('vibe-browse error: ' + String(e?.stack ?? e).slice(0, 400), 1)
}
