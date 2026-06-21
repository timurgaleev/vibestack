// vibe-browse-daemon — persistent Playwright session over a unix socket.
//
// Keeps ONE browser + page alive so element refs survive across separate client
// calls: `snapshot` tags interactive elements with `data-vibe-ref` and returns
// `@e1`, `@e2`, …; a later `click @e1` (a different process) resolves the ref on
// the same live page. This is the cross-call interaction the stateless shim
// cannot do. No browser extension — Playwright drives Chromium over CDP directly.
//
// Protocol: newline-delimited JSON. Request `{"verb":"click","args":["@e1"]}`,
// reply `{"ok":true,...}` or `{"ok":false,"error":"…"}`. `__stop` shuts down.
import net from 'node:net'
import { existsSync, mkdirSync, unlinkSync, writeFileSync, readFileSync } from 'node:fs'
import { tmpdir, homedir } from 'node:os'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const SOCK = process.env.VIBE_BROWSE_DAEMON_SOCK ?? join(tmpdir(), 'vibe-browse', 'daemon.sock')
const NAV_TIMEOUT = Number(process.env.VIBE_BROWSE_TIMEOUT ?? 30000)
const ACTION_TIMEOUT = Number(process.env.VIBE_BROWSE_ACTION_TIMEOUT ?? 10000)

const getChromium = async () => {
  const cands = [
    process.env.VIBE_BROWSE_DEP_DIR && join(process.env.VIBE_BROWSE_DEP_DIR, 'node_modules/playwright/index.js'),
    join(process.cwd(), 'node_modules/playwright/index.js'),
  ].filter(Boolean)
  for (const c of cands) {
    if (!existsSync(c)) continue
    const m = await import(pathToFileURL(c).href)
    return m.chromium ?? m.default?.chromium
  }
  console.error('BROWSE_NOT_AVAILABLE: Playwright not installed')
  process.exit(2)
}

const resolveUrl = (raw) =>
  raw.startsWith('file://~') ? 'file://' + join(homedir(), raw.slice(8))
  : raw.startsWith('file://./') ? 'file://' + resolve(process.cwd(), raw.slice(9))
  : raw
// A ref ("@e3") resolves to the data-attribute selector snapshot assigned; any
// other string is used as a raw CSS selector.
const sel = (a) => (a && a.startsWith('@')) ? `[data-vibe-ref="${a.slice(1)}"]` : a

const chromium = await getChromium()
const browser = await chromium.launch({ headless: process.env.VIBE_BROWSE_HEADED !== '1' })
const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 })
const page = await context.newPage()
// Record the most recent JS dialog so `dialog` can report it, then act on it.
// Default accepts; `dialog dismiss` flips the next action to dismiss.
let lastDialog = null
let dialogAction = 'accept'
page.on('dialog', async (d) => {
  lastDialog = { type: d.type(), message: d.message() }
  try { dialogAction === 'dismiss' ? await d.dismiss() : await d.accept() } catch {}
  dialogAction = 'accept'
})

const loc = (a) => page.locator(sel(a)).first()
const handlers = {
  async goto({ args }) { const r = await page.goto(resolveUrl(args[0]), { waitUntil: 'networkidle', timeout: NAV_TIMEOUT }); return { url: page.url(), status: r?.status() ?? null } },
  async snapshot() {
    const elements = await page.evaluate(() => {
      const q = 'a,button,input,textarea,select,[role=button],[onclick],[tabindex]'
      const els = [...document.querySelectorAll(q)].filter((e) => e.offsetParent !== null).slice(0, 200)
      return els.map((e, i) => {
        const r = 'e' + (i + 1)
        e.setAttribute('data-vibe-ref', r)
        const label = (e.innerText || e.value || e.getAttribute('aria-label') || e.placeholder || e.name || '').trim().slice(0, 60)
        return { ref: '@' + r, tag: e.tagName.toLowerCase(), type: e.type || '', label }
      })
    })
    return { elements }
  },
  async click({ args }) { await loc(args[0]).click({ timeout: ACTION_TIMEOUT }); return { ok: true } },
  async fill({ args }) { await loc(args[0]).fill(args.slice(1).join(' '), { timeout: ACTION_TIMEOUT }); return { ok: true } },
  async type({ args }) { await loc(args[0]).pressSequentially(args.slice(1).join(' '), { timeout: ACTION_TIMEOUT }); return { ok: true } },
  async hover({ args }) { await loc(args[0]).hover({ timeout: ACTION_TIMEOUT }); return { ok: true } },
  async check({ args }) { await loc(args[0]).check({ timeout: ACTION_TIMEOUT }); return { ok: true } },
  async uncheck({ args }) { await loc(args[0]).uncheck({ timeout: ACTION_TIMEOUT }); return { ok: true } },
  async select({ args }) { await loc(args[0]).selectOption(args.slice(1).join(' ')); return { ok: true } },
  async press({ args }) { await page.keyboard.press(args[0]); return { ok: true } },
  async screenshot({ args }) { mkdirSync(join(args[0], '..'), { recursive: true }); await page.screenshot({ path: args[0], fullPage: true }); return { screenshot: args[0] } },
  async text() { const t = await page.evaluate(() => document.body?.innerText ?? ''); return { text: t.slice(0, 4000) } },
  async url() { return { url: page.url() } },
  async back() { await page.goBack(); return { url: page.url() } },
  async forward() { await page.goForward(); return { url: page.url() } },
  async reload() { await page.reload(); return { url: page.url() } },
  async eval({ args }) { const r = await page.evaluate(`(() => (${args.join(' ')}))()`); return { result: typeof r === 'string' ? r : JSON.stringify(r) } },
  // Upload: set file inputs on a <input type=file>. `upload <sel|@ref> <path...>`.
  async upload({ args }) { await loc(args[0]).setInputFiles(args.slice(1)); return { ok: true, files: args.slice(1) } },
  // Dialog: report the last JS dialog seen; `dialog dismiss` makes the NEXT one dismiss.
  async dialog({ args }) {
    if (args[0] === 'dismiss') { dialogAction = 'dismiss'; return { ok: true, next: 'dismiss' } }
    if (args[0] === 'accept') { dialogAction = 'accept'; return { ok: true, next: 'accept' } }
    return { dialog: lastDialog }
  },
  // Cookies: get | set <json> | save <path> | load <path> | import-cdp <cdp-url>.
  // import-cdp connects to a Chrome started with --remote-debugging-port and copies
  // its cookies into this session (the upstream's CDP cookie-import, brand-clean).
  async cookies({ args }) {
    const op = args[0] ?? 'get'
    if (op === 'get') return { cookies: await context.cookies() }
    if (op === 'set') { await context.addCookies(JSON.parse(args.slice(1).join(' '))); return { ok: true } }
    if (op === 'save') { writeFileSync(args[1], JSON.stringify(await context.storageState(), null, 2)); return { ok: true, saved: args[1] } }
    if (op === 'load') { const st = JSON.parse(readFileSync(args[1], 'utf8')); if (st.cookies) await context.addCookies(st.cookies); return { ok: true, loaded: args[1] } }
    if (op === 'import-cdp') {
      const ext = await chromium.connectOverCDP(args[1])
      try { const src = ext.contexts()[0]; if (src) await context.addCookies(await src.cookies()) } finally { await ext.close() }
      return { ok: true, imported: 'cdp' }
    }
    return { ok: false, error: 'cookies: get | set <json> | save <path> | load <path> | import-cdp <url>' }
  },
  async status() { return { mode: 'daemon', url: page.url() } },
}

async function shutdown() {
  try { await browser.close() } catch {}
  try { server.close() } catch {}
  try { unlinkSync(SOCK) } catch {}
  process.exit(0)
}

try { unlinkSync(SOCK) } catch {}
mkdirSync(join(SOCK, '..'), { recursive: true })

const server = net.createServer((conn) => {
  let buf = ''
  conn.on('data', async (d) => {
    buf += d.toString()
    let idx
    while ((idx = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, idx); buf = buf.slice(idx + 1)
      if (!line.trim()) continue
      let msg
      try { msg = JSON.parse(line) } catch { conn.write(JSON.stringify({ ok: false, error: 'bad json' }) + '\n'); continue }
      if (msg.verb === '__stop') { conn.write(JSON.stringify({ ok: true, stopped: true }) + '\n'); await shutdown(); return }
      const h = handlers[msg.verb]
      if (!h) { conn.write(JSON.stringify({ ok: false, error: 'NOT_SUPPORTED:' + msg.verb }) + '\n'); continue }
      try { const res = await h({ args: msg.args ?? [] }); conn.write(JSON.stringify({ ok: true, ...res }) + '\n') }
      catch (e) { conn.write(JSON.stringify({ ok: false, error: String(e?.message ?? e).slice(0, 200) }) + '\n') }
    }
  })
})

process.on('SIGINT', shutdown)
process.on('SIGTERM', shutdown)
server.listen(SOCK, () => {
  writeFileSync(join(SOCK, '..', 'daemon.pid'), String(process.pid))
  console.log('vibe-browse daemon listening on ' + SOCK)
})
