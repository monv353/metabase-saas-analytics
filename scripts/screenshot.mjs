// Capture docs/dashboard.png with headless Chrome over the SSH tunnel (no Puppeteer; raw DevTools protocol).
// Run via `make screenshot`. Needs: tunnel on localhost:3300, Chrome with --remote-debugging-port=9333,
// MB_ADMIN_EMAIL / MB_ADMIN_PASSWORD in the environment (loaded from .env by the Makefile).
import fs from 'node:fs'
const base = 'http://localhost:3300'
const s = await (await fetch(base + '/api/session', { method: 'POST', headers: { 'content-type': 'application/json' },
  body: JSON.stringify({ username: process.env.MB_ADMIN_EMAIL, password: process.env.MB_ADMIN_PASSWORD }) })).json()
const tabs = await (await fetch('http://127.0.0.1:9333/json/list')).json()
const ws = new WebSocket(tabs.find(t => t.type === 'page').webSocketDebuggerUrl)
await new Promise(r => ws.onopen = r)
let id = 0; const pending = {}
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pending[m.id]) { pending[m.id](m); delete pending[m.id] } }
const send = (method, params = {}) => new Promise(r => { pending[++id] = r; ws.send(JSON.stringify({ id, method, params })) })
await send('Network.enable')
await send('Network.setCookie', { name: 'metabase.SESSION', value: s.id, domain: 'localhost', path: '/', httpOnly: true })
await send('Emulation.setDeviceMetricsOverride', { width: 1600, height: 2350, deviceScaleFactor: 1, mobile: false })
await send('Page.navigate', { url: base + '/dashboard/' + (process.env.DASHBOARD_ID || 2) + '?date_range=' })
const evalJs = async expr => (await send('Runtime.evaluate', { expression: expr, returnByValue: true })).result?.result?.value
for (let i = 0; i < 60; i++) {
  await new Promise(r => setTimeout(r, 2000))
  const st = await evalJs(`({t: document.body.innerText.includes('Top 10 accounts'), svg: document.querySelectorAll('svg').length, load: document.querySelectorAll('[data-testid=loading-indicator], .LoadingSpinner').length})`)
  console.log(JSON.stringify(st))
  if (st && st.t && st.load === 0 && st.svg > 10) break
}
await new Promise(r => setTimeout(r, 5000))
const shot = await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false })
fs.writeFileSync(process.argv[2], Buffer.from(shot.result.data, 'base64'))
ws.close(); process.exit(0)
