import { test, expect } from "@playwright/test";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(here, "out");
const PAGE = "/user1.asp";

async function fixture(request, name) {
  const r = await request.post("/__fixture", { data: { name } });
  expect(r.ok()).toBeTruthy();
}
async function posts(request) {
  return (await (await request.get("/__posts")).json());
}
async function waitPosts(request, n) {
  await expect.poll(async () => (await posts(request)).length, { timeout: 5000 }).toBe(n);
  return posts(request);
}
const full = (p) => JSON.parse(p.amng_custom);
const custom = (p) => Object.fromEntries(Object.entries(full(p)).filter(([k]) => k.startsWith("wgcui_")));
const decode = (v) => v.replace(/%0A/g, "\n").replace(/%7C/g, "|").replace(/%25/g, "%");
const row = (page, n) => page.locator(`#slot${n}`);

test.beforeEach(async ({ request }) => {
  await request.post("/__reset");
});

test("P01 empty status: 5 rows, text link, no button", async ({ page, request }) => {
  await fixture(request, "empty");
  await page.goto(PAGE);
  await expect(page.locator("#tunnels_body tr[id^=slot]")).toHaveCount(5);
  for (let n = 1; n <= 5; n++) {
    await expect(row(page, n).locator(".btn-upload")).toHaveText("upload a conf…");
    await expect(row(page, n).locator("input.button_gen")).toHaveCount(0);
    await expect(row(page, n).locator(".c-word")).toHaveCount(0);
    await expect(row(page, n).locator(".dot")).toHaveAttribute("title", "empty");
    await expect(row(page, n).locator(".c-exit button")).toHaveCount(0);
  }
});

test("P02 two tunnels: UP / DEGRADED rendered", async ({ page, request }) => {
  await fixture(request, "two");
  await page.goto(PAGE);
  const r1 = row(page, 1), r2 = row(page, 2);
  await expect(r1.locator(".c-word")).toHaveText("up");
  await expect(r1.locator(".dot")).toHaveAttribute("title", "up");
  await expect(r1.locator(".c-hs")).toHaveText("12 s ago");
  await expect(r1.locator(".c-traffic")).toContainText("down 214 MB");
  await expect(r1.locator(".c-traffic")).toContainText("up 1.6 MB");
  await expect(r1.locator(".c-endpoint")).toHaveText("3.77.117.65:51820");
  await expect(r1.locator(".c-key")).toHaveText("qM3IC+fx");
  await expect(r1.locator(".c-exit-ip")).toHaveText("203.0.113.77");
  await expect(r1.locator(".c-exit-age")).toHaveCount(0);
  await expect(r1.locator("input.button_gen")).toHaveValue("Stop");
  await expect(r2.locator(".c-word")).toHaveText("degraded");
  await expect(r2.locator(".c-exit-ip")).toHaveCount(0);
  await expect(r2.locator("input.button_gen")).toHaveValue("Stop");
  await expect(page.locator("#msg2 .c-missing")).toHaveText("missing: iptables markin, endpoint rule 11302");
  await expect(row(page, 3).locator("input.button_gen")).toHaveCount(0);
  await expect(row(page, 3).locator(".btn-upload")).toBeVisible();
  await expect(page.locator("#log_body")).toContainText("wgc: start wgc1 ok");
  await expect(page.locator("tr.rule")).toHaveCount(3);
  await page.screenshot({ path: path.join(out, "p02.png"), fullPage: true });
});

test("P03 file for slot 3 -> saveconf post", async ({ page, request }) => {
  await fixture(request, "empty");
  await page.goto(PAGE);
  const file = path.join(here, "fixtures", "conf-fake.conf");
  await row(page, 3).locator('input[type="file"]').setInputFiles(file);
  const ps = await waitPosts(request, 1);
  const p = ps[0];
  expect(p.action_script).toBe("start_wgcui");
  expect(p.action_mode).toBe("apply");
  expect(p.action_wait).toBe("5");
  const c = custom(p);
  expect(Object.keys(c).sort()).toEqual(["wgcui_action", "wgcui_conf", "wgcui_len", "wgcui_target"]);
  expect(c.wgcui_action).toBe("saveconf");
  expect(c.wgcui_target).toBe("3");
  expect(c.wgcui_len).toBe(Buffer.byteLength(c.wgcui_conf));
  expect(c.wgcui_conf).not.toMatch(/[\r\n]/);
  expect(c.wgcui_conf).toContain("%0A");
  expect(c.wgcui_conf).not.toContain("||||");
  expect(c.wgcui_conf).not.toContain("|");
  expect(decode(c.wgcui_conf)).toBe(fs.readFileSync(file, "utf8").replace(/\r/g, ""));
});

test("P03b file > 4096 bytes is refused client-side", async ({ page, request }) => {
  await fixture(request, "empty");
  await page.goto(PAGE);
  const big = path.join(out, "big.conf");
  fs.writeFileSync(big, "# FAKE\n" + "x".repeat(5000) + "\n");
  await row(page, 2).locator('input[type="file"]').setInputFiles(big);
  await expect(page.locator("#msg2 .file-err")).toContainText("too large");
  await page.waitForTimeout(300);
  expect(await posts(request)).toHaveLength(0);
});

test("P04 Stop / Start / Keep it post exact keys", async ({ page, request }) => {
  await fixture(request, "two");
  await page.goto(PAGE);
  const keys = (p) => Object.keys(custom(p)).sort();
  await row(page, 1).locator("input.button_gen").click();
  let ps = await waitPosts(request, 1);
  expect(custom(ps[0])).toEqual({ wgcui_action: "stop", wgcui_target: "1" });
  expect(keys(ps[0])).toEqual(["wgcui_action", "wgcui_target"]);
  await fixture(request, "down");
  await expect(row(page, 1).locator("input.button_gen")).toHaveValue("Start", { timeout: 5000 });
  await row(page, 1).locator("input.button_gen").click();
  ps = await waitPosts(request, 2);
  expect(custom(ps[1])).toEqual({ wgcui_action: "start", wgcui_target: "1" });
  await expect(page.locator('input[value="Try 5 min"]')).toHaveCount(0);
  await fixture(request, "pendingtry");
  await expect(page.locator("#try_bar")).toBeVisible();
  await page.locator('#try_bar input[value="Keep it"]').click();
  ps = await waitPosts(request, 3);
  expect(custom(ps[2])).toEqual({ wgcui_action: "confirm" });
});

test("P05 rules: add device rule, apply; invalid custom address blocked", async ({ page, request }) => {
  await fixture(request, "two");
  await page.goto(PAGE);
  await expect(page.locator("tr.rule")).toHaveCount(3);
  for (let i = 0; i < 3; i++) { await page.locator("tr.rule .r-del").first().click(); }
  await expect(page.locator("tr.rule")).toHaveCount(0);
  // invalid first
  await page.locator("#btn_add").click();
  const rule = page.locator("tr.rule").first();
  await rule.locator(".r-dev").selectOption({ label: "custom…" });
  await expect(rule.locator(".r-custom")).toBeVisible();
  await rule.locator(".r-custom").fill("999.1.1.1");
  await page.locator("#btn_apply").click();
  await expect(rule.locator(".r-src-err")).toContainText("invalid");
  await page.waitForTimeout(300);
  expect(await posts(request)).toHaveLength(0);
  // valid device rule
  await rule.locator(".r-dev").selectOption({ label: "laptop (192.168.2.233)" });
  await page.locator("#btn_apply").click();
  const ps = await waitPosts(request, 1);
  expect(custom(ps[0])).toEqual({ wgcui_action: "saverules", wgcui_rules: "wgc1 192.168.2.233 any", wgcui_len: 22 });
});

test("P05b rules: CIDR custom and bad destination", async ({ page, request }) => {
  await fixture(request, "two");
  await page.goto(PAGE);
  for (let i = 0; i < 3; i++) { await page.locator("tr.rule .r-del").first().click(); }
  await page.locator("#btn_add").click();
  await page.locator("#btn_add").click();
  const rules = page.locator("tr.rule");
  await rules.nth(0).locator(".r-tunnel").selectOption("3");
  await rules.nth(0).locator(".r-dev").selectOption({ label: "custom…" });
  await rules.nth(0).locator(".r-custom").fill("10.0.0.0/8");
  await rules.nth(0).locator(".r-dst").fill("1.2.3.4");
  await rules.nth(1).locator(".r-dst").fill("1.2.3.4/33");
  await page.locator("#btn_apply").click();
  await expect(rules.nth(1).locator(".r-dst-err")).toContainText("invalid");
  expect(await posts(request)).toHaveLength(0);
  await rules.nth(1).locator(".r-dst").fill("5.6.7.0/24");
  await page.locator("#btn_apply").click();
  const ps = await waitPosts(request, 1);
  expect(custom(ps[0]).wgcui_rules).toBe("wgc3 10.0.0.0/8 1.2.3.4%0Awgc1 any 5.6.7.0/24");
});

test("P06 hostile status shows as text, nothing executes", async ({ page, request }) => {
  const dialogs = [];
  page.on("dialog", (d) => { dialogs.push(d.message()); d.dismiss(); });
  await fixture(request, "hostile");
  await page.goto(PAGE);
  await expect(page.locator("#log_body")).toContainText("</script><script>alert(2)</script>");
  await expect(page.locator(".r-dev option", { hasText: "<img src=x onerror=alert(1)>" })).toHaveCount(1);
  await expect(page.locator("img")).toHaveCount(0);
  await expect(page.locator("tr.rule .r-custom")).toHaveValue('1.2.3.4\\"x');
  await page.waitForTimeout(500);
  expect(dialogs).toEqual([]);
  const scripts = await page.evaluate(() => document.querySelectorAll("script:not([src])").length);
  expect(scripts).toBe(2); // the page's own two inline scripts
});

test("P07 pending disables buttons, then enables; 30 s timeout message", async ({ page, request }) => {
  await fixture(request, "pending");
  await page.goto(PAGE);
  await expect(row(page, 1).locator("input.btn-primary")).toBeDisabled();
  await expect(page.locator("#btn_apply")).toBeDisabled();
  await fixture(request, "two");
  await expect(row(page, 1).locator("input.btn-primary")).toBeEnabled({ timeout: 5000 });
  // timeout path
  await fixture(request, "pending");
  const page2 = await page.context().newPage();
  await page2.clock.install();
  await page2.goto(PAGE);
  await expect(row(page2, 1).locator("input.btn-primary")).toBeDisabled();
  for (let i = 0; i < 33; i++) {
    await page2.clock.runFor(1000);
    await page2.waitForTimeout(60);
  }
  await expect(page2.locator("#top_msg")).toContainText(
    "no answer from the router, check with SSH: wgc.sh status all");
});

test("P08 pending_try bar and Confirm", async ({ page, request }) => {
  await fixture(request, "pendingtry");
  await page.goto(PAGE);
  const bar = page.locator("#try_bar");
  await expect(bar).toBeVisible();
  await expect(bar).toContainText("wgc2 is on a trial run (max 300 s)");
  await bar.locator('input[value="Keep it"]').click();
  const ps = await waitPosts(request, 1);
  expect(custom(ps[0])).toEqual({ wgcui_action: "confirm" });
});

test("P09 http warning visible on http, hidden on https", async ({ page, request, browser }) => {
  await fixture(request, "empty");
  await page.goto(PAGE);
  await expect(page.locator("#http_warn")).toBeVisible();
  const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
  const p2 = await ctx.newPage();
  let ok = false;
  for (let i = 0; i < 20 && !ok; i++) {
    try { await p2.goto("https://127.0.0.1:8443" + PAGE); ok = true; } catch { await p2.waitForTimeout(250); }
  }
  expect(ok).toBe(true);
  expect(await p2.evaluate(() => location.protocol)).toBe("https:");
  await expect(p2.locator("#tunnels_body tr[id^=slot]")).toHaveCount(5);
  await expect(p2.locator("#http_warn")).toBeHidden();
  await ctx.close();
});

test("P12 failed last action: message verbatim in red next to its row", async ({ page, request }) => {
  await fixture(request, "failed");
  await page.goto(PAGE);
  const m = page.locator("#msg3 .wgc-err");
  await expect(m).toHaveText("wgc.sh: bad Endpoint <b>x</b>");
  await expect(page.locator("#msg3 b")).toHaveCount(0);
  await expect(page.locator("#msg1")).toHaveCount(0);
});

test("P13 remove conf: double-click no post; yes after 1 s; no path", async ({ page, request }) => {
  await fixture(request, "down");
  await page.goto(PAGE);
  const r1 = row(page, 1);
  await r1.locator(".btn-del").dblclick();
  await expect(r1.locator(".btn-confirm-del")).toBeDisabled();
  await page.waitForTimeout(300);
  expect(await posts(request)).toHaveLength(0);
  await page.waitForTimeout(1100);
  await expect(r1.locator(".btn-confirm-del")).toBeEnabled();
  await r1.locator(".btn-confirm-del").click();
  const ps = await waitPosts(request, 1);
  expect(custom(ps[0])).toEqual({ wgcui_action: "deleteconf", wgcui_target: "1" });
  // cancel path on row 2
  await expect(row(page, 2).locator(".btn-del")).toBeEnabled({ timeout: 5000 });
  await expect(row(page, 2).locator(".btn-del")).toHaveText("remove conf");
  await row(page, 2).locator(".btn-del").click();
  await page.waitForTimeout(1200);
  await row(page, 2).locator(".btn-cancel").click();
  await expect(row(page, 2).locator(".btn-del")).toBeVisible();
  await expect(row(page, 2).locator(".btn-confirm-del")).toHaveCount(0);
  await page.waitForTimeout(300);
  expect(await posts(request)).toHaveLength(1);
});

test("P14 no auto refresh by default; checkbox gives one POST per 30 s", async ({ page, request }) => {
  await fixture(request, "two");
  await page.clock.install();
  await page.goto(PAGE);
  await expect(row(page, 1).locator(".c-word")).toHaveText("up");
  for (let i = 0; i < 25; i++) { await page.clock.runFor(1000); await page.waitForTimeout(30); }
  expect(await posts(request)).toHaveLength(0);
  await page.locator("#auto_chk").check();
  for (let i = 0; i < 31; i++) { await page.clock.runFor(1000); await page.waitForTimeout(60); }
  const ps = await waitPosts(request, 1);
  expect(custom(ps[0])).toEqual({ wgcui_action: "refresh" });
});

test("P15 check_error shown in red in Conf column", async ({ page, request }) => {
  await fixture(request, "checkerr");
  await page.goto(PAGE);
  const e = row(page, 3).locator(".c-conf .c-check-err");
  await expect(e).toHaveText("bad <b>Endpoint</b> line 4");
  await expect(row(page, 3).locator("b")).toHaveCount(0);
  const color = await e.evaluate((n) => getComputedStyle(n).color);
  expect(color).toBe("rgb(255, 107, 107)");
});

test("P16 encoding of |, %, CRLF in conf", async ({ page, request }) => {
  await fixture(request, "empty");
  await page.goto(PAGE);
  const f = path.join(out, "enc.conf");
  const orig = "[Interface]\r\n# a|\r\n|b|\r\n50% off %41\r\nlast";
  fs.writeFileSync(f, orig);
  await row(page, 4).locator('input[type="file"]').setInputFiles(f);
  const ps = await waitPosts(request, 1);
  const v = custom(ps[0]).wgcui_conf;
  expect(decode(v)).toBe(orig.replace(/\r/g, ""));
  expect(v).not.toMatch(/[|\r\n]/);
  expect(v.replace(/%25|%7C|%0A/g, "")).not.toContain("%");
  expect(v).toContain("%7C");
  expect(v).toContain("50%25 off %2541");
});

test("P17 rules_skipped warning", async ({ page, request }) => {
  await fixture(request, "skipped");
  await page.goto(PAGE);
  await expect(page.locator(".rules-skipped")).toHaveText("2 invalid line(s) in rules will be dropped by Apply");
  await fixture(request, "two");
  await page.reload();
  await expect(row(page, 1).locator(".c-word")).toHaveText("up");
  await expect(page.locator(".rules-skipped")).toHaveCount(0);
  await fixture(request, "empty");
  await page.reload();
  await expect(page.locator("#tunnels_body tr[id^=slot]")).toHaveCount(5);
  await expect(page.locator(".rules-skipped")).toHaveCount(0);
});

test("P18 posts foreign keys from the template, drops stale wgcui_*", async ({ page, request }) => {
  await fixture(request, "empty");
  await page.goto(PAGE);
  await row(page, 3).locator('input[type="file"]').setInputFiles(path.join(here, "fixtures", "conf-fake.conf"));
  const ps = await waitPosts(request, 1);
  const f = full(ps[0]);
  expect(f.uidivstats_version_local).toBe("v3.0.4");
  expect(f._Diversion_page).toBe("user1.asp");
  expect(f.wgcui_action).toBe("saveconf");
  expect(f.wgcui_old).toBeUndefined();
  expect(Object.keys(f).sort()).toEqual(["_Diversion_page", "uidivstats_version_local",
    "wgcui_action", "wgcui_conf", "wgcui_len", "wgcui_target"]);
});

test("P19 size limits: 2100-byte conf and total over 2900 refused", async ({ page, request }) => {
  await fixture(request, "empty");
  await page.goto(PAGE);
  const big = path.join(out, "conf2100.conf");
  fs.writeFileSync(big, "#" + "a".repeat(2099));
  await row(page, 1).locator('input[type="file"]').setInputFiles(big);
  await expect(page.locator("#msg1 .file-err")).toContainText("2048");
  await page.waitForTimeout(300);
  expect(await posts(request)).toHaveLength(0);
  // foreign value 2800 bytes + 300-byte conf
  await request.post("/__custom_settings", { data: JSON.stringify({ other: "z".repeat(2800) }) });
  await page.goto(PAGE);
  const mid = path.join(out, "conf300.conf");
  fs.writeFileSync(mid, "#" + "b".repeat(299));
  await row(page, 2).locator('input[type="file"]').setInputFiles(mid);
  await expect(page.locator("#send_err")).toContainText(/settings too large \(\d+ bytes, limit 2900\)/);
  await page.waitForTimeout(300);
  expect(await posts(request)).toHaveLength(0);
});

test("P20 foreign_settings from status.js wins over the template", async ({ page, request }) => {
  await fixture(request, "two");
  await page.goto(PAGE);
  await row(page, 1).locator("input.btn-primary").click();
  const ps = await waitPosts(request, 1);
  const f = full(ps[0]);
  expect(f.status_key).toBe("from_status");
  expect(f.uidivstats_version_local).toBeUndefined();
  expect(f.wgcui_action).toBe("stop");
});

for (const [name, fx] of [["refused saverules", "rulesfail"], ["unrelated rc 0 last", "rulesrefresh"]]) {
  test(`P21 rules rows kept after Apply (${name})`, async ({ page, request }) => {
    await fixture(request, fx);
    await page.goto(PAGE);
    await expect(row(page, 1).locator(".c-word")).toHaveText("up");
    await page.locator("#btn_add").click();
    await page.locator("tr.rule .r-dst").fill("1.2.3.4");
    await page.locator("#btn_apply").click();
    const ps = await waitPosts(request, 1);
    expect(custom(ps[0]).wgcui_action).toBe("saverules");
    await expect(page.locator("#btn_apply")).toBeEnabled({ timeout: 5000 });
    await expect(page.locator("tr.rule")).toHaveCount(1);
    await expect(page.locator("tr.rule .r-dst")).toHaveValue("1.2.3.4");
    if (fx === "rulesfail") { await expect(page.locator("#rules_msg")).toContainText("rules refused: line 1"); }
  });
}

test("P22 action does not navigate/reload the page", async ({ page, request }) => {
  await fixture(request, "two");
  await page.goto(PAGE);
  await page.evaluate(() => { window.__m = "kept"; });
  await row(page, 1).locator("input.btn-primary").click();
  await waitPosts(request, 1);
  await expect(row(page, 1).locator("input.btn-primary")).toBeEnabled({ timeout: 5000 });
  await page.waitForTimeout(6000); // longer than action_wait
  expect(await page.evaluate(() => window.__m)).toBe("kept");
  expect(await page.evaluate(() => performance.getEntriesByType("navigation").length)).toBe(1);
});

test("P22b failed POST: message and buttons re-enabled", async ({ page, request }) => {
  await fixture(request, "two");
  await page.goto(PAGE);
  await request.post("/__failnext");
  await row(page, 1).locator("input.btn-primary").click();
  await expect(page.locator("#send_err")).toContainText("could not reach the router (HTTP 500)");
  await expect(row(page, 1).locator("input.btn-primary")).toBeEnabled();
});

test("P23 exit address shown as plain text, no check link, no age", async ({ page, request }) => {
  await fixture(request, "two");
  await page.goto(PAGE);
  await expect(row(page, 1).locator(".c-exit")).toHaveText("203.0.113.77");
  await expect(row(page, 2).locator(".c-exit")).toHaveText("");
  await expect(page.locator(".btn-exit")).toHaveCount(0);
  await expect(page.locator(".c-exit-age")).toHaveCount(0);
});

test("P24 remove conf only when down", async ({ page, request }) => {
  await fixture(request, "two");
  await page.goto(PAGE);
  await expect(row(page, 1).locator(".c-word")).toHaveText("up");
  await expect(row(page, 1).locator(".btn-del")).toHaveCount(0);
  await expect(row(page, 2).locator(".btn-del")).toHaveCount(0);
  await expect(row(page, 3).locator(".btn-del")).toHaveCount(0);
  await fixture(request, "down");
  await page.reload();
  await expect(row(page, 1).locator(".btn-del")).toHaveCount(1);
  await expect(row(page, 1).locator(".c-exit")).toHaveText("");
});

test("P25 successful action shows no OK row; compact button style", async ({ page, request }) => {
  await fixture(request, "ok");
  await page.goto(PAGE);
  await expect(row(page, 1).locator(".c-word")).toHaveText("up");
  await expect(page.locator(".msgrow .wgc-err")).toHaveCount(0);
  await expect(page.locator("#tunnels_body")).not.toContainText("OK");
  const w = await row(page, 1).locator("input.btn-primary").evaluate((b) => b.getBoundingClientRect().width);
  expect(w).toBeLessThan(100);
  const bg = await row(page, 1).locator(".dot").evaluate((d) => d.style.background);
  expect(bg).toContain("rgb(126, 217, 87)");
});

test("P26 rules block: empty hint, styled controls, text links", async ({ page, request }) => {
  await fixture(request, "empty");
  await page.goto(PAGE);
  await expect(page.locator(".rules-empty")).toHaveText("No rules yet. Add one to send traffic into a tunnel.");
  await expect(page.locator("#btn_add")).toHaveText("add rule");
  await page.locator("#btn_add").click();
  await expect(page.locator(".rules-empty")).toHaveCount(0);
  const r = page.locator("tr.rule");
  await expect(r.locator("select.input_option")).toHaveCount(2);
  await expect(r.locator("input.input_20_table")).toHaveCount(4);
  await expect(r.locator(".r-del")).toHaveText("remove");
  await expect(page.locator("#rules_card th").last()).toHaveText("");
  const fits = await r.evaluate((tr) => [...tr.querySelectorAll("select,input")].every((e) => {
    const c = e.closest("td").getBoundingClientRect(), b = e.getBoundingClientRect();
    return b.width === 0 || b.right <= c.right + 0.5;
  }));
  expect(fits).toBe(true);
  await r.locator(".r-del").click();
  await expect(page.locator(".rules-empty")).toHaveCount(1);
});

test("P27 screenshot of the rules block", async ({ page, request }) => {
  await fixture(request, "two");
  await page.goto(PAGE);
  await expect(page.locator("tr.rule")).toHaveCount(3);
  await page.locator("#btn_add").click();
  await page.locator("tr.rule").last().locator(".r-dev").selectOption({ label: "custom…" });
  await page.locator("#rules_card").screenshot({ path: path.join(out, "rules.png") });
});

test("P28 rules render (incl. disabled) and Apply posts exact lines", async ({ page, request }) => {
  await fixture(request, "two");
  await page.goto(PAGE);
  const rules = page.locator("tr.rule");
  await expect(rules).toHaveCount(3);
  await expect(rules.nth(0).locator(".r-name")).toHaveValue("Laptop");
  await expect(rules.nth(0).locator(".r-desc")).toHaveValue("Netflix through Germany");
  await expect(rules.nth(0).locator(".r-on")).toBeChecked();
  await expect(rules.nth(1).locator(".r-name")).toHaveValue("");
  await expect(rules.nth(2).locator(".r-on")).not.toBeChecked();
  await expect(rules.nth(2).locator(".r-name")).toHaveCSS("opacity", "0.55");
  await expect(rules.nth(0).locator(".r-name")).toHaveCSS("opacity", "1");
  await expect(rules.nth(0).locator(".r-name")).toHaveAttribute("maxlength", "40");
  await expect(rules.nth(0).locator(".r-desc")).toHaveAttribute("maxlength", "120");
  await page.locator("#rules_card").screenshot({ path: path.join(out, "rules.png") });
  await page.locator("#btn_apply").click();
  const ps = await waitPosts(request, 1);
  const c = custom(ps[0]);
  expect(c.wgcui_rules).toBe(
    "wgc1 192.168.2.233 any   # Laptop: Netflix through Germany%0A" +
    "wgc2 192.168.2.50 8.8.8.0/24%0A" +
    "#off wgc2 192.168.2.77 any   # TV");
  expect(c.wgcui_len).toBe(c.wgcui_rules.length);
});

test("P29 name validation and disabling a rule", async ({ page, request }) => {
  await fixture(request, "two");
  await page.goto(PAGE);
  const rules = page.locator("tr.rule");
  await rules.nth(1).locator(".r-name").fill("a:b");
  await page.locator("#btn_apply").click();
  await expect(rules.nth(1).locator(".r-name-err")).toContainText("no #");
  await rules.nth(1).locator(".r-name").fill("Привет");
  await page.locator("#btn_apply").click();
  await expect(rules.nth(1).locator(".r-name-err")).not.toHaveText("");
  await rules.nth(1).locator(".r-name").fill("ok");
  await rules.nth(1).locator(".r-desc").fill("bad # hash");
  await page.locator("#btn_apply").click();
  await expect(rules.nth(1).locator(".r-desc-err")).not.toHaveText("");
  await page.waitForTimeout(300);
  expect(await posts(request)).toHaveLength(0);
  await rules.nth(1).locator(".r-desc").fill("");
  await rules.nth(0).locator(".r-on").uncheck();
  await expect(rules.nth(0).locator(".r-name")).toHaveCSS("opacity", "0.55");
  await page.locator("#btn_apply").click();
  const ps = await waitPosts(request, 1);
  const lines = custom(ps[0]).wgcui_rules.split("%0A");
  expect(lines[0]).toBe("#off wgc1 192.168.2.233 any   # Laptop: Netflix through Germany");
  expect(lines[1]).toBe("wgc2 192.168.2.50 8.8.8.0/24   # ok");
});
