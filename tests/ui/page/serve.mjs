// Fake router web server for page tests. Node >= 18, no dependencies.
import http from "node:http";
import https from "node:https";
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(here, "out");
const asp = path.join(here, "..", "..", "..", "router", "wgcui.asp");
const HTTP_PORT = Number(process.env.WGC_HTTP_PORT || 8099);
const HTTPS_PORT = Number(process.env.WGC_HTTPS_PORT || 8443);
fs.mkdirSync(out, { recursive: true });
const postsFile = path.join(out, "posts.jsonl");

let fixture = "empty";
let counter = 0;
let failNext = 0;
const csFile = path.join(here, "fixtures", "custom_settings.json");
let customSettings = null; // per-test override
const csDefault = () => fs.readFileSync(csFile, "utf8").trim(); // bumped per POST so "generated" changes like on a real router

const asus = {
  "/state.js": "state.js", "/general.js": "general.js", "/popup.js": "popup.js",
  "/help.js": "help.js", "/tmmenu.js": "tmmenu.js", "/validator.js": "validator.js",
  "/client_function.js": "client_function.js",
  "/js/jquery.js": "jquery.js",
  "/index_style.css": "index_style.css", "/form_style.css": "form_style.css",
};

function readBody(req) {
  return new Promise((res) => {
    const c = [];
    req.on("data", (d) => c.push(d));
    req.on("end", () => res(Buffer.concat(c).toString("utf8")));
  });
}
function posts() {
  try {
    return fs.readFileSync(postsFile, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  } catch { return []; }
}
function send(res, code, type, body) {
  res.writeHead(code, { "Content-Type": type, "Cache-Control": "no-store" });
  res.end(body);
}

async function handler(req, res) {
  const url = new URL(req.url, "http://x");
  const p = url.pathname;
  if (req.method === "GET" && p === "/user1.asp") {
    const t = fs.readFileSync(asp, "utf8").replace("<% get_custom_settings(); %>", () => customSettings ?? csDefault())
      .replace(/<%[\s\S]*?%>/g, "");
    return send(res, 200, "text/html; charset=utf-8", t);
  }
  if (req.method === "GET" && asus[p]) {
    const f = path.join(here, "fixtures", "asus", asus[p]);
    return send(res, 200, p.endsWith(".css") ? "text/css" : "application/javascript", fs.readFileSync(f));
  }
  if (req.method === "GET" && p === "/ext/wgc/status.js") {
    const f = path.join(here, "fixtures", `status-${fixture}.js`);
    if (!fs.existsSync(f)) return send(res, 404, "text/plain", "no fixture");
    const t = fs.readFileSync(f, "utf8").replace(/"generated":\s*(\d+)/, (_, n) => `"generated":${Number(n) + counter}`);
    return send(res, 200, "application/javascript", t);
  }
  if (req.method === "POST" && p === "/__fixture") {
    const b = JSON.parse(await readBody(req));
    if (!/^[a-z]+$/.test(b.name)) return send(res, 400, "text/plain", "bad name");
    fixture = b.name;
    return send(res, 200, "text/plain", "ok");
  }
  if (req.method === "POST" && p === "/__custom_settings") {
    const b = await readBody(req);
    JSON.parse(b);
    customSettings = b;
    return send(res, 200, "text/plain", "ok");
  }
  if (req.method === "POST" && p === "/__failnext") { failNext = 1; return send(res, 200, "text/plain", "ok"); }
  if (req.method === "POST" && p === "/__reset") {
    failNext = 0;
    customSettings = null;
    fs.writeFileSync(postsFile, "");
    counter = 0; fixture = "empty";
    return send(res, 200, "text/plain", "ok");
  }
  if (req.method === "GET" && p === "/__posts") {
    return send(res, 200, "application/json", JSON.stringify(posts()));
  }
  if (req.method === "POST" && p === "/start_apply.htm") {
    const body = await readBody(req);
    if (failNext) { failNext = 0; return send(res, 500, "text/plain", "fail"); }
    const obj = Object.fromEntries(new URLSearchParams(body));
    fs.appendFileSync(postsFile, JSON.stringify(obj) + "\n");
    counter += 1;
    return send(res, 200, "text/html", "");
  }
  send(res, 404, "text/plain", "not found");
}

fs.writeFileSync(postsFile, "");
http.createServer(handler).listen(HTTP_PORT, "127.0.0.1", () => console.log("http on", HTTP_PORT));

const key = path.join(out, "key.pem"), crt = path.join(out, "cert.pem");
try {
  execFileSync("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", crt,
    "-days", "2", "-subj", "/CN=localhost"], { stdio: "ignore" });
  https.createServer({ key: fs.readFileSync(key), cert: fs.readFileSync(crt) }, handler)
    .listen(HTTPS_PORT, "127.0.0.1", () => console.log("https on", HTTPS_PORT));
} catch (e) {
  console.error("https listener disabled:", e.message);
}
