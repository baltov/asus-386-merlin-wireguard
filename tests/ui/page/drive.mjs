// Control server for a visible Chromium. Usage: node drive.mjs <baseUrl> <profileDir> <port>
import http from 'node:http';
import { chromium } from 'playwright';

const [baseUrl, profileDir, portArg] = process.argv.slice(2);
if (!baseUrl || !profileDir || !portArg) {
  console.error('usage: node drive.mjs <baseUrl> <profileDir> <port>');
  process.exit(2);
}

const ctx = await chromium.launchPersistentContext(profileDir, {
  headless: false,
  viewport: process.env.DRIVE_VIEWPORT === "window" ? null : { width: 1280, height: 900 },
  ignoreHTTPSErrors: true,
});
const page = ctx.pages()[0] || (await ctx.newPage());
await page.goto(baseUrl.replace(/\/+$/, '') + '/', { waitUntil: 'load' }).catch((e) => console.log('initial goto failed:', e.message));

const info = async () => ({ url: page.url(), title: await page.title() });

const routes = {
  'GET /status': info,
  'POST /goto': async ({ url }) => {
    await page.goto(url, { waitUntil: 'load' });
    return info();
  },
  'POST /shot': async ({ path, fullPage }) => {
    await page.screenshot({ path, fullPage: !!fullPage });
    return { ok: true };
  },
  'POST /text': async ({ selector }) => ({ text: await page.locator(selector).first().textContent().catch(() => null) }),
  'POST /count': async ({ selector }) => ({ count: await page.locator(selector).count() }),
  'POST /click': async ({ selector }) => {
    await page.locator(selector).first().click();
    return { ok: true };
  },
  'POST /fill': async ({ selector, value }) => {
    await page.locator(selector).first().fill(value);
    return { ok: true };
  },
  'POST /eval': async ({ js }) => {
    try {
      const result = await page.evaluate(js);
      return { result: result === undefined ? null : result };
    } catch (e) {
      return { error: e.message };
    }
  },
  'POST /wait': async ({ selector, timeout }) => {
    try {
      await page.waitForSelector(selector, { timeout: timeout ?? 30000 });
      return { ok: true };
    } catch (e) {
      return { error: e.message };
    }
  },
  'POST /setfile': async ({ selector, path }) => {
    await page.locator(selector).first().setInputFiles(path);
    return { ok: true };
  },
};

const server = http.createServer(async (req, res) => {
  const send = (code, obj) => {
    const body = JSON.stringify(obj);
    console.log(`${req.method} ${req.url} -> ${code} ${body.slice(0, 100)}`);
    res.writeHead(code, { 'content-type': 'application/json' });
    res.end(body);
  };
  try {
    const path = new URL(req.url, 'http://x').pathname;
    let raw = '';
    for await (const c of req) raw += c;
    if (req.method === 'POST' && path === '/quit') {
      send(200, { ok: true });
      server.close();
      await ctx.close().catch(() => {});
      process.exit(0);
    }
    const h = routes[`${req.method} ${path}`];
    if (!h) return send(404, { error: 'not found' });
    send(200, await h(raw ? JSON.parse(raw) : {}));
  } catch (e) {
    send(500, { error: e.message });
  }
});

process.on('uncaughtException', (e) => console.log('uncaught:', e.message));
process.on('unhandledRejection', (e) => console.log('unhandled:', e?.message ?? e));
ctx.on('close', () => process.exit(0));
server.listen(Number(portArg), '127.0.0.1', () => console.log('READY'));
