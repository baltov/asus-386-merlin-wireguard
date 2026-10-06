<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<!-- wgcui-page -->
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta http-equiv="X-UA-Compatible" content="IE=Edge"/>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
<meta http-equiv="Pragma" content="no-cache">
<meta http-equiv="Expires" content="-1">
<link rel="shortcut icon" href="images/favicon.png">
<link rel="icon" href="images/favicon.png">
<title>WireGuard Client</title>
<link rel="stylesheet" type="text/css" href="index_style.css">
<link rel="stylesheet" type="text/css" href="form_style.css">
<style>
.wgc-warn{background:#FFCC00;color:#000;font-size:12px;line-height:18px;padding:4px 10px;margin:10px 0}
.wgc-try{background:#3C4A4F;color:#FFF;font-size:12px;line-height:18px;padding:5px 10px;margin:10px 0}
.wgc-top{margin:6px 0;font-size:12px;line-height:18px}
.wgc-err{color:#FF6B6B;font-size:12px;line-height:18px;white-space:pre-wrap;word-break:break-word}
table.wgc-tbl td{font-size:13px;line-height:18px;vertical-align:middle;color:#FFF;word-break:break-word}
table.wgc-tbl th{vertical-align:middle}
table.wgc-tbl tr.msgrow td{padding:2px 8px}
.wgc-nw{white-space:nowrap}
.wgc-log{white-space:pre-wrap;word-break:break-all;font-family:monospace;font-size:12px;line-height:16px;margin:0;padding:6px;background:#2F3A3E;color:#FFF;max-height:160px;overflow-y:auto}
.wgc-act{min-width:0!important;width:auto!important;height:auto!important;padding:3px 14px!important;font-size:12px!important;line-height:18px!important;margin:0!important}
.wgc-link{background:none;border:0;padding:0;margin:0;color:#9ECAE6;text-decoration:underline;cursor:pointer;font-family:inherit;font-size:11px;line-height:18px}
.wgc-link:disabled{color:#B8C2C7;text-decoration:none;cursor:default}
.c-remove{margin-top:3px}
.wgc-autolbl{font-size:11px;color:#B8C2C7;margin-left:8px}
</style>
<script language="JavaScript" type="text/javascript" src="/js/jquery.js"></script>
<script language="JavaScript" type="text/javascript" src="/state.js"></script>
<script language="JavaScript" type="text/javascript" src="/general.js"></script>
<script language="JavaScript" type="text/javascript" src="/popup.js"></script>
<script language="JavaScript" type="text/javascript" src="/help.js"></script>
<script language="JavaScript" type="text/javascript" src="/tmmenu.js"></script>
<script language="JavaScript" type="text/javascript" src="/validator.js"></script>
<script language="JavaScript" type="text/javascript" src="/client_function.js"></script>
<script>
var custom_settings = <% get_custom_settings(); %>;
</script>
<script>
"use strict";
var STATUS_URL = "/ext/wgc/status.js";
var POLL_MS = 1000, IDLE_MS = 30000, SLOW_MS = 10000, TIMEOUT_MS = 30000, STALE_OK_MS = 5000;
var DEL_READY_MS = 1000, DEL_IDLE_MS = 10000;
var MAX_CONF = 2048, MAX_TOTAL = 2900;
var S = null;            /* last status */
var waiting = null;      /* {scope, gen, t0} while an action we sent is not finished */
var pendingT0 = null;
var noAnswer = false;
var timer = null;
var rulesModel = [];
var rulesDirty = false;
var rulesLoaded = false;
var delMode = 0, delReady = false, delTimer = null, delIdleTimer = null;
var fileErr = {};
var rulesErr = {};

function byId(id) { return document.getElementById(id); }
function el(tag, cls, text) {
  var e = document.createElement(tag);
  if (cls) { e.className = cls; }
  if (text !== undefined && text !== null) { e.textContent = String(text); }
  return e;
}
function clear(n) { while (n.firstChild) { n.removeChild(n.firstChild); } }

function initial() {
  var p = location.pathname.substring(1);
  document.form.current_page.value = p;
  document.form.next_page.value = p;
  show_menu();
  byId("http_warn").style.display = (location.protocol === "http:") ? "block" : "none";
  renderRules();
  load();
}

/* ---------- loading status.js ---------- */
function load() {
  clearTimeout(timer);
  window.wgcui = null;
  var s = document.createElement("script");
  s.onload = function () {
    if (s.parentNode) { s.parentNode.removeChild(s); }
    if (window.wgcui && typeof window.wgcui === "object") { onStatus(window.wgcui); }
    else { timer = setTimeout(load, 1000); }
  };
  s.onerror = function () {
    if (s.parentNode) { s.parentNode.removeChild(s); }
    timer = setTimeout(load, 1000);
  };
  s.src = STATUS_URL + "?" + Date.now();
  document.head.appendChild(s);
}

function onStatus(st) {
  var now = Date.now();
  S = st;
  if (waiting && st.pending !== true &&
      (st.generated !== waiting.gen || now - waiting.t0 > STALE_OK_MS)) {
    var sc = waiting.scope;
    waiting = null;
    /* keep the user's rows unless a saverules explicitly succeeded */
    if (sc === "rules" && st.last && st.last.action === "saverules" && st.last.rc === 0) { rulesDirty = false; }
  }
  if (st.pending === true) {
    if (pendingT0 === null) { pendingT0 = now; }
  } else {
    pendingT0 = null;
    noAnswer = false;
  }
  var t0 = waiting ? waiting.t0 : pendingT0;
  if (t0 !== null && now - t0 > TIMEOUT_MS) {
    noAnswer = true;
    waiting = null;
    pendingT0 = null;
  }
  renderAll();
  clearTimeout(timer);
  if (waiting || (st.pending === true && !noAnswer)) { timer = setTimeout(load, POLL_MS); }
  else if (st.pending === true) { timer = setTimeout(load, SLOW_MS); }
  else if (autoOn()) { timer = setTimeout(idle, IDLE_MS); }
}

function autoOn() { return byId("auto_chk").checked; }

function autoChanged() {
  if (waiting || (S && S.pending === true)) { return; }
  clearTimeout(timer);
  if (autoOn()) { timer = setTimeout(idle, IDLE_MS); }
}

function idle() {
  if (!autoOn()) { return; }
  if (document.visibilityState === "visible" && S && S.pending !== true) {
    sendAction({ wgcui_action: "refresh" }, "refresh");
  } else {
    load();
  }
}

/* ---------- sending ---------- */
function utf8Len(str) {
  return encodeURIComponent(str).replace(/%[0-9A-Fa-f]{2}/g, "x").length;
}

/* The firmware replaces the whole custom_settings.txt with amng_custom,
   so every foreign key must be posted back. */
function baseSettings() {
  var src = (S && S.foreign_settings && typeof S.foreign_settings === "object")
    ? S.foreign_settings
    : (window.custom_settings && typeof window.custom_settings === "object" ? window.custom_settings : {});
  var out = {};
  Object.keys(src).forEach(function (k) {
    if (k.indexOf("wgcui_") !== 0) { out[k] = src[k]; }
  });
  return out;
}

function sendErr(msg) {
  var b = byId("send_err");
  clear(b);
  if (msg) { b.appendChild(el("div", "wgc-err", msg)); }
}

function sendAction(obj, scope) {
  var ours = Object.assign({}, obj);
  var big = null;
  if (ours.wgcui_action === "saveconf") { big = ours.wgcui_conf; }
  if (ours.wgcui_action === "saverules") { big = ours.wgcui_rules; }
  if (big !== null) {
    var bl = utf8Len(big);
    if (bl > MAX_CONF) { sendErr("value too large (" + bl + " bytes, limit " + MAX_CONF + ")"); return false; }
    ours.wgcui_len = bl;
  }
  var json = JSON.stringify(Object.assign({}, baseSettings(), ours));
  var n = utf8Len(json);
  if (n > MAX_TOTAL) { sendErr("settings too large (" + n + " bytes, limit " + MAX_TOTAL + ")"); return false; }
  sendErr("");
  document.form.amng_custom.value = json;
  waiting = { scope: scope, act: ours.wgcui_action, gen: S ? S.generated : null, t0: Date.now() };
  noAnswer = false;
  clearTimeout(timer);
  renderAll();
  postForm(scope);
  timer = setTimeout(load, POLL_MS);
  return true;
}

/* Post like the form would, but with fetch: a form submit makes the firmware
   reload this page after action_wait and all page state would be lost. */
function postForm(scope) {
  var body = new URLSearchParams();
  var els = document.form.elements;
  for (var i = 0; i < els.length; i++) {
    if (els[i].type === "hidden" && els[i].name) { body.append(els[i].name, els[i].value); }
  }
  var fail = function (code) {
    if (!waiting || waiting.scope !== scope) { return; }
    waiting = null;
    sendErr("could not reach the router (HTTP " + code + ")");
    renderAll();
    clearTimeout(timer);
    timer = setTimeout(load, POLL_MS);
  };
  fetch("/start_apply.htm", {
    method: "POST",
    credentials: "same-origin",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: body
  }).then(function (r) {
    if (r.status !== 200) { fail(r.status); }
  }, function () { fail(0); });
}

function encodeVal(t) {
  return String(t).replace(/\r/g, "").replace(/%/g, "%25").replace(/\|/g, "%7C").replace(/\n/g, "%0A");
}

/* ---------- helpers ---------- */
function fmtAge(s) {
  if (s === null || s === undefined) { return "never"; }
  s = Number(s);
  if (s < 60) { return s + " s ago"; }
  if (s < 3600) { return Math.floor(s / 60) + " min ago"; }
  return Math.floor(s / 3600) + " h ago";
}
function fmtBytes(n) {
  n = Number(n) || 0;
  var u = ["B", "KB", "MB", "GB", "TB"], i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  if (i === 0) { return n + " B"; }
  return (n >= 100 ? String(Math.floor(n)) : n.toFixed(1)) + " " + u[i];
}
function rowDisabled(scope) {
  if (S && S.pending === true && !noAnswer) { return true; }
  if (waiting && waiting.scope !== "refresh" &&
      (waiting.scope === scope || waiting.scope === "all")) { return true; }
  return false;
}
function btn(label, onclick, disabled) {
  var b = el("input", "button_gen wgc-act");
  b.type = "button"; b.value = label; b.disabled = !!disabled;
  b.onclick = onclick;
  return b;
}
function lastMsg(last) {
  /* success is shown by the state change itself; only errors get a line */
  if (last.rc === 0) { return null; }
  var m = el("div", "wgc-err");
  m.textContent = (last.message !== undefined && last.message !== null && last.message !== "")
    ? String(last.message) : "failed (rc=" + last.rc + ")";
  return m;
}
var TUNNEL_ACTIONS = { saveconf: 1, deleteconf: 1, check: 1, start: 1, stop: 1 };

/* ---------- render ---------- */
function renderAll() {
  renderTop();
  renderTunnels();
  renderRules();
  renderLog();
}

function renderTop() {
  var top = byId("top_msg");
  clear(top);
  if (!S) { return; }
  if (noAnswer) {
    top.appendChild(el("div", "wgc-err", "no answer from the router, check with SSH: wgc.sh status all"));
  }
  if (S.busy === true) { top.appendChild(el("div", "wgc-err", "another action is running")); }
  if (S.error) { top.appendChild(el("div", "wgc-err", S.error)); }
  var l = S.last;
  if (l && typeof l === "object" && l.action && l.action !== "refresh" &&
      l.action !== "saverules" && !TUNNEL_ACTIONS[l.action]) {
    var lm = lastMsg(l);
    if (lm) { top.appendChild(lm); }
  }
  var pt = byId("try_bar");
  clear(pt);
  if (S.pending_try) {
    var secs = (S.pending_try.seconds !== undefined) ? S.pending_try.seconds : S.pending_try.seconds_left;
    pt.style.display = "block";
    pt.appendChild(el("span", null, "wgc" + S.pending_try.target + " is on a trial run (max " + secs + " s) "));
    pt.appendChild(btn("Keep it", function () {
      sendAction({ wgcui_action: "confirm" }, "confirm");
    }, rowDisabled("confirm")));
  } else {
    pt.style.display = "none";
  }
}

function renderTunnels() {
  var tb = byId("tunnels_body");
  clear(tb);
  var list = (S && S.tunnels) || [];
  for (var i = 1; i <= 5; i++) {
    var t = list[i - 1] || { conf: false, state: "noconf" };
    tb.appendChild(tunnelRow(i, t));
  }
}

var C_MUTED = "#B8C2C7";
var DOT_COLOR = { up: "#7ED957", degraded: "#F2C94C", down: "#8C9BA5", noconf: "#5A666C" };
function cell(cls) {
  var td = el("td", cls);
  td.style.padding = "5px 8px";
  td.style.verticalAlign = "middle";
  return td;
}
function mut(tag, cls, text) {
  var e = el(tag, "muted " + cls, text);
  e.style.color = C_MUTED;
  e.style.fontSize = "11px";
  return e;
}
function white(e) { e.style.color = "#FFF"; return e; }

function lnk(label, cls, onclick, disabled) {
  var b = el("button", "wgc-link " + cls, label);
  b.type = "button"; b.disabled = !!disabled;
  if (onclick) { b.onclick = onclick; }
  return b;
}

function tunnelRow(n, t) {
  var frag = document.createDocumentFragment();
  var tr = el("tr");
  tr.id = "slot" + n;
  var st = String(t.state);
  var has = t.conf === true && st !== "noconf";
  var word = (st === "noconf") ? "empty" : st;
  var scope = String(n), tgt = scope, dis = rowDisabled(scope);

  /* Tunnel: dot + name; state word and missing items only with a conf */
  var c0 = cell("c-tunnel");
  var dot = el("span", "dot dot-" + st.replace(/[^a-z]/g, ""));
  dot.title = word;
  dot.style.cssText = "display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:6px;vertical-align:middle;background:" +
    (DOT_COLOR[st] || DOT_COLOR.noconf) + (st === "noconf" ? ";box-shadow:0 0 0 1px #B8C2C7" : "");
  c0.appendChild(dot);
  var nm = white(el("span", "c-name", "wgc" + n));
  nm.style.fontWeight = "bold";
  c0.appendChild(nm);
  if (has) {
    c0.appendChild(mut("div", "c-word", word));
  }
  tr.appendChild(c0);

  /* Peer (or the upload link for an empty slot) */
  var c1 = cell("c-conf");
  c1.style.whiteSpace = "nowrap";
  c1.style.overflow = "hidden";
  c1.style.textOverflow = "ellipsis";
  if (has) {
    c1.appendChild(white(el("div", "c-endpoint", t.endpoint || "?")));
    c1.appendChild(mut("div", "c-key", String(t.pubkey || "").substring(0, 8)));
  } else {
    var fi = el("input");
    fi.type = "file"; fi.style.display = "none"; fi.disabled = dis;
    fi.onchange = function () { onFile(n, fi); };
    c1.appendChild(fi);
    var up = lnk("upload a conf…", "btn-upload", function () { fi.click(); }, dis);
    up.style.color = C_MUTED;
    c1.appendChild(up);
  }
  if (t.check_error) { c1.appendChild(el("div", "wgc-err c-check-err", t.check_error)); }
  tr.appendChild(c1);

  /* Exit address */
  var c2 = cell("c-exit");
  if (has && st !== "down" && t.exit_ip) {
    c2.appendChild(white(el("span", "c-exit-ip", t.exit_ip)));
  }
  tr.appendChild(c2);

  /* Handshake, traffic */
  var hs = cell("c-hs wgc-nw");
  hs.textContent = has ? fmtAge(t.handshake_age) : "";
  hs.style.whiteSpace = "nowrap";
  tr.appendChild(hs);
  var tf = cell("c-traffic wgc-nw");
  tf.style.whiteSpace = "nowrap";
  if (has) {
    tf.appendChild(el("div", null, "down " + fmtBytes(t.rx)));
    tf.appendChild(el("div", null, "up " + fmtBytes(t.tx)));
  }
  tr.appendChild(tf);

  /* Action: one compact primary button, none for an empty slot */
  var a = cell("c-act");
  if (has) {
    var pb;
    if (st === "down") {
      pb = btn("Start", function () { sendAction({ wgcui_action: "start", wgcui_target: tgt }, scope); }, dis);
    } else {
      pb = btn("Stop", function () { sendAction({ wgcui_action: "stop", wgcui_target: tgt }, scope); }, dis);
    }
    pb.className += " btn-primary";
    a.appendChild(pb);
  }
  if (has && st === "down") {
    var rm = el("div", "c-remove");
    if (delMode === n) {
      rm.appendChild(mut("span", "", "remove? "));
      rm.appendChild(lnk("yes", "btn-confirm-del", function () {
        if (!delReady) { return; }
        delReset();
        sendAction({ wgcui_action: "deleteconf", wgcui_target: tgt }, scope);
      }, dis || !delReady));
      rm.appendChild(document.createTextNode(" "));
      rm.appendChild(lnk("no", "btn-cancel", function () { delReset(); renderTunnels(); }, false));
    } else {
      var rc = lnk("remove conf", "btn-del", function () {
        if (delMode) { return; }
        delMode = n; delReady = false;
        clearTimeout(delTimer); clearTimeout(delIdleTimer);
        delTimer = setTimeout(function () { delReady = true; renderTunnels(); }, DEL_READY_MS);
        delIdleTimer = setTimeout(function () { delReset(); renderTunnels(); }, DEL_IDLE_MS);
        renderTunnels();
      }, dis);
      rc.style.color = C_MUTED;
      rm.appendChild(rc);
    }
    a.appendChild(rm);
  }
  tr.appendChild(a);
  frag.appendChild(tr);

  /* error line, full width under the row (errors only) */
  var msg = null;
  var l = S && S.last;
  if (!has && fileErr[n]) { msg = el("div", "wgc-err file-err", fileErr[n]); }
  else if (l && typeof l === "object" && TUNNEL_ACTIONS[l.action]) {
    var tg = String(l.target);
    if (tg === scope || (tg === "all" && l.rc !== 0)) { msg = lastMsg(l); }
  }
  var miss = (has && t.missing && t.missing.length) ? mut("div", "c-missing", "missing: " + t.missing.join(", ")) : null;
  if (msg || miss) {
    var mr = el("tr", "msgrow");
    mr.id = "msg" + n;
    var mc = el("td"); mc.colSpan = 6;
    if (miss) { miss.style.paddingLeft = "15px"; mc.appendChild(miss); }
    if (msg) { mc.appendChild(msg); }
    mr.appendChild(mc);
    frag.appendChild(mr);
  }
  return frag;
}

function delReset() {
  clearTimeout(delTimer); clearTimeout(delIdleTimer);
  delMode = 0; delReady = false;
}

function onFile(n, input) {
  var f = input.files && input.files[0];
  if (!f) { return; }
  fileErr[n] = "";
  if (f.size > MAX_CONF) {
    fileErr[n] = "file too large (" + f.size + " bytes, max " + MAX_CONF + ")";
    renderTunnels();
    return;
  }
  var r = new FileReader();
  r.onload = function () {
    var text = String(r.result);
    if (text.length > MAX_CONF) {
      fileErr[n] = "file too large (max " + MAX_CONF + ")";
      renderTunnels();
      return;
    }
    sendAction({ wgcui_action: "saveconf", wgcui_target: String(n), wgcui_conf: encodeVal(text) }, String(n));
  };
  r.onerror = function () { fileErr[n] = "cannot read file"; renderTunnels(); };
  r.readAsText(f);
}

/* ---------- rules ---------- */
var IPV4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?:\/(\d{1,2}))?$/;
function validAddr(v, allowAny) {
  if (allowAny && v === "any") { return true; }
  var m = IPV4.exec(v);
  if (!m) { return false; }
  for (var i = 1; i <= 4; i++) { if (Number(m[i]) > 255) { return false; } }
  if (m[5] !== undefined && Number(m[5]) > 32) { return false; }
  return true;
}

function modelFromStatus() {
  var devs = (S && S.devices) || [], out = [];
  var rs = (S && S.rules) || [];
  for (var i = 0; i < rs.length; i++) {
    var r = rs[i], src = String(r.src), sel = "__custom", custom = src;
    if (src === "any") { sel = "any"; custom = ""; }
    else {
      for (var j = 0; j < devs.length; j++) { if (devs[j].ip === src) { sel = src; custom = ""; } }
    }
    out.push({ on: r.enabled !== false, name: String(r.name || ""), desc: String(r.desc || ""),
      t: String(r.tunnel).replace(/^wgc/, ""), sel: sel, custom: custom, dst: String(r.dst) });
  }
  return out;
}

function renderRules() {
  var host = byId("rules_body");
  if (S && !rulesDirty) { rulesModel = modelFromStatus(); rulesLoaded = true; rulesErr = {}; }
  var dis = rowDisabled("rules");
  /* while the user is editing, only refresh the enabled state in place */
  if (rulesDirty && host.firstChild) {
    var els = byId("rules_card").querySelectorAll("select,input,button");
    for (var k = 0; k < els.length; k++) { els[k].disabled = dis; }
    renderRulesMsg();
    return;
  }
  buildRules(dis);
  renderRulesMsg();
}

function renderRulesMsg() {
  var box = byId("rules_msg");
  clear(box);
  var sk = S ? Number(S.rules_skipped) : 0;
  if (sk > 0) {
    box.appendChild(el("div", "wgc-warn rules-skipped", sk + " invalid line(s) in rules will be dropped by Apply"));
  }
  var l = S && S.last;
  if (l && typeof l === "object" && l.action === "saverules") {
    var lm = lastMsg(l);
    if (lm) { box.appendChild(lm); }
  }
  byId("rules_msg_row").style.display = box.firstChild ? "" : "none";
}

function buildRules(dis) {
  var host = byId("rules_body");
  clear(host);
  var devs = (S && S.devices) || [];
  rulesModel.forEach(function (r, idx) {
    var tr = el("tr");
    tr.className = "rule";
    var dimEls = [];
    function dim() { dimEls.forEach(function (e) { e.style.opacity = r.on ? "" : ".55"; }); }
    var tdOn = cell();
    var cb = el("input", "r-on"); cb.type = "checkbox"; cb.checked = !!r.on; cb.disabled = dis;
    cb.style.margin = "0";
    cb.title = "enabled";
    cb.onchange = function () { r.on = cb.checked; rulesDirty = true; dim(); };
    tdOn.appendChild(cb); tr.appendChild(tdOn);

    var tdN = cell();
    var ni = el("input", "input_20_table r-name"); ni.type = "text"; ni.maxLength = 40; ni.value = r.name;
    ni.placeholder = "name"; ni.disabled = dis;
    ni.style.cssText = "width:100%;box-sizing:border-box;height:25px;margin:0;";
    ni.oninput = function () { r.name = ni.value; rulesDirty = true; };
    var di2 = el("input", "input_20_table r-desc"); di2.type = "text"; di2.maxLength = 120; di2.value = r.desc;
    di2.placeholder = "description"; di2.disabled = dis;
    di2.style.cssText = "width:100%;box-sizing:border-box;height:25px;margin:4px 0 0 0;font-size:11px;color:#B8C2C7;";
    di2.oninput = function () { r.desc = di2.value; rulesDirty = true; };
    tdN.appendChild(ni); tdN.appendChild(di2);
    tdN.appendChild(el("div", "wgc-err r-name-err", rulesErr[idx] && rulesErr[idx].name ? rulesErr[idx].name : ""));
    tdN.appendChild(el("div", "wgc-err r-desc-err", rulesErr[idx] && rulesErr[idx].desc ? rulesErr[idx].desc : ""));
    tr.appendChild(tdN);
    dimEls.push(ni, di2);

    var td1 = cell();
    var ts = el("select", "input_option r-tunnel"); ts.disabled = dis; ts.style.cssText = "width:100%;box-sizing:border-box;height:25px;margin:0;font-size:12px;";
    for (var n = 1; n <= 5; n++) {
      var o = el("option", null, "wgc" + n); o.value = String(n); ts.appendChild(o);
    }
    ts.value = r.t;
    ts.onchange = function () { r.t = ts.value; rulesDirty = true; };
    td1.appendChild(ts); tr.appendChild(td1);
    dimEls.push(ts);

    var td2 = cell();
    var ds = el("select", "input_option r-dev"); ds.disabled = dis; ds.style.cssText = "width:100%;box-sizing:border-box;height:25px;margin:0;font-size:12px;";
    var oa = el("option", null, "any (whole LAN)"); oa.value = "any"; ds.appendChild(oa);
    devs.forEach(function (d) {
      var o = el("option", null, (d.name || "?") + " (" + d.ip + ")"); o.value = String(d.ip); ds.appendChild(o);
    });
    var oc = el("option", null, "custom…"); oc.value = "__custom"; ds.appendChild(oc);
    ds.value = r.sel;
    if (ds.value !== r.sel) { r.sel = "any"; ds.value = "any"; }
    var ci = el("input", "input_20_table r-custom"); ci.type = "text"; ci.style.cssText = "width:100%;box-sizing:border-box;height:25px;margin:4px 0 0 0;"; ci.value = r.custom; ci.disabled = dis;
    ci.placeholder = "a.b.c.d or a.b.c.d/n";
    ci.style.display = (r.sel === "__custom") ? "block" : "none";
    ci.oninput = function () { r.custom = ci.value; rulesDirty = true; };
    ds.onchange = function () {
      r.sel = ds.value; rulesDirty = true;
      ci.style.display = (r.sel === "__custom") ? "block" : "none";
    };
    td2.appendChild(ds); td2.appendChild(ci);
    dimEls.push(ds, ci);
    var e2 = el("div", "wgc-err r-src-err", rulesErr[idx] && rulesErr[idx].src ? rulesErr[idx].src : "");
    td2.appendChild(e2);
    tr.appendChild(td2);

    var td3 = cell();
    var di = el("input", "input_20_table r-dst"); di.type = "text"; di.style.cssText = "width:100%;box-sizing:border-box;height:25px;margin:0;"; di.value = r.dst; di.disabled = dis;
    di.oninput = function () { r.dst = di.value; rulesDirty = true; };
    td3.appendChild(di);
    dimEls.push(di);
    td3.appendChild(el("div", "wgc-err r-dst-err", rulesErr[idx] && rulesErr[idx].dst ? rulesErr[idx].dst : ""));
    tr.appendChild(td3);

    var td4 = cell();
    var x = lnk("remove", "r-del", function () {
      rulesModel.splice(idx, 1); rulesDirty = true; rulesErr = {}; buildRules(rowDisabled("rules"));
    }, dis);
    x.style.color = C_MUTED;
    td4.appendChild(x); tr.appendChild(td4);
    dim();
    host.appendChild(tr);
  });
  if (rulesModel.length === 0) {
    var er = el("tr", "rules-empty");
    var ec = cell(); ec.colSpan = 6;
    ec.appendChild(mut("span", "", "No rules yet. Add one to send traffic into a tunnel."));
    er.appendChild(ec);
    host.appendChild(er);
  }
  byId("btn_add").disabled = dis;
  byId("btn_apply").disabled = dis;
}

function addRule() {
  rulesModel.push({ on: true, name: "", desc: "", t: "1", sel: "any", custom: "", dst: "any" });
  rulesDirty = true;
  buildRules(rowDisabled("rules"));
}

function applyRules() {
  var lines = [], errs = {}, bad = false;
  rulesModel.forEach(function (r, i) {
    var src = (r.sel === "__custom") ? String(r.custom).trim() : r.sel;
    var dst = String(r.dst).trim();
    var e = {};
    if (!validAddr(src, true)) { e.src = "invalid address (a.b.c.d, a.b.c.d/n or any)"; }
    if (!validAddr(dst, true)) { e.dst = "invalid destination (a.b.c.d, a.b.c.d/n or any)"; }
    var nm = String(r.name).trim(), ds = String(r.desc).trim();
    if (!/^[\x20-\x7E]*$/.test(nm) || nm.indexOf("#") >= 0 || nm.indexOf(":") >= 0) {
      e.name = "name: printable ASCII only, no # and no :";
    }
    if (!/^[\x20-\x7E]*$/.test(ds) || ds.indexOf("#") >= 0) {
      e.desc = "description: printable ASCII only, no #";
    }
    if (e.src || e.dst || e.name || e.desc) { errs[i] = e; bad = true; }
    else {
      var ln = (r.on ? "" : "#off ") + "wgc" + r.t + " " + src + " " + dst;
      if (nm !== "" || ds !== "") { ln += "   # " + nm + (ds !== "" ? ": " + ds : ""); }
      lines.push(ln);
    }
  });
  rulesErr = errs;
  if (bad) { buildRules(rowDisabled("rules")); return; }
  sendAction({ wgcui_action: "saverules", wgcui_rules: encodeVal(lines.join("\n")) }, "rules");
}

/* ---------- log ---------- */
function renderLog() {
  var pre = byId("log_body");
  var lines = (S && S.log) || [];
  pre.textContent = lines.join("\n");
  byId("btn_log").disabled = rowDisabled("log");
}
</script>
</head>
<body onload="initial();">
<div id="TopBanner"></div>
<div id="Loading" class="popup_bg"></div>
<iframe name="hidden_frame" id="hidden_frame" src="about:blank" width="0" height="0" frameborder="0"></iframe>
<form method="post" name="form" id="ruleForm" action="/start_apply.htm" target="hidden_frame">
<input type="hidden" name="action_script" value="start_wgcui">
<input type="hidden" name="current_page" value="">
<input type="hidden" name="next_page" value="">
<input type="hidden" name="modified" value="0">
<input type="hidden" name="action_mode" value="apply">
<input type="hidden" name="action_wait" value="5">
<input type="hidden" name="first_time" value="">
<input type="hidden" name="SystemCmd" value="">
<input type="hidden" name="preferred_lang" id="preferred_lang" value="<% nvram_get("preferred_lang"); %>">
<input type="hidden" name="firmver" value="<% nvram_get("firmver"); %>">
<input type="hidden" name="amng_custom" id="amng_custom" value="">
<table class="content" align="center" cellpadding="0" cellspacing="0">
<tr>
<td width="17">&nbsp;</td>
<td valign="top" width="202">
<div id="mainMenu"></div>
<div id="subMenu"></div></td>
<td valign="top">
<div id="tabMenu" class="submenuBlock"></div>
<table width="98%" border="0" align="left" cellpadding="0" cellspacing="0">
<tr>
<td valign="top">
<table width="760px" border="0" cellpadding="4" cellspacing="0" bordercolor="#6b8fa3" class="FormTitle" id="FormTitle">
<tbody>
<tr bgcolor="#4D595D">
<td valign="top">
<div>&nbsp;</div>
<div class="formfonttitle" style="text-align:center;">WireGuard Client</div>
<div style="margin:10px 0 10px 5px;" class="splitLine"></div>
<div id="http_warn" class="wgc-warn" style="display:none;">This page uses HTTP: an uploaded conf (with its private key) travels unencrypted inside your LAN.</div>
<div id="top_msg" class="wgc-top"></div>
<div id="send_err" class="wgc-top"></div>
<div id="try_bar" class="wgc-try" style="display:none;"></div>

<table width="100%" border="1" align="center" cellpadding="4" cellspacing="0" bordercolor="#6b8fa3" class="FormTable wgc-tbl" style="border:0px;width:100%;table-layout:fixed;" id="tunnels_card">
<colgroup><col style="width:13%"><col style="width:31%"><col style="width:18%"><col style="width:11%"><col style="width:12%"><col style="width:15%"></colgroup>
<thead><tr><td colspan="6">Tunnels</td></tr></thead>
<tr><th style="width:13%">Tunnel</th><th style="width:31%">Peer</th><th style="width:18%">Exit address</th><th style="width:11%;white-space:nowrap">Handshake</th><th style="width:12%;white-space:nowrap">Traffic</th><th style="width:15%"></th></tr>
<tbody id="tunnels_body"></tbody>
</table>
<div style="line-height:10px;">&nbsp;</div>

<table width="100%" border="1" align="center" cellpadding="4" cellspacing="0" bordercolor="#6b8fa3" class="FormTable wgc-tbl" style="border:0px;width:100%;table-layout:fixed;" id="rules_card">
<colgroup><col style="width:5%"><col style="width:21%"><col style="width:11%"><col style="width:31%"><col style="width:24%"><col style="width:8%"></colgroup>
<thead><tr><td colspan="6">Rules</td></tr></thead>
<tr id="rules_msg_row" style="display:none"><td colspan="6"><div id="rules_msg"></div></td></tr>
<tr><th style="width:5%"></th><th style="width:21%">Name</th><th style="width:11%">Tunnel</th><th style="width:31%">Device</th><th style="width:24%">Destination</th><th style="width:8%"></th></tr>
<tbody id="rules_body"></tbody>
<tr><td colspan="6">
<button type="button" class="wgc-link" id="btn_add" onclick="addRule();" style="background:none;border:0;padding:0;margin:0 12px 0 0;font-size:11px;color:#B8C2C7;text-decoration:underline;cursor:pointer;">add rule</button>
<input type="button" class="button_gen wgc-act" id="btn_apply" value="Apply rules" onclick="applyRules();" >
</td></tr>
</table>
<div style="line-height:10px;">&nbsp;</div>

<table width="100%" border="1" align="center" cellpadding="4" cellspacing="0" bordercolor="#6b8fa3" class="FormTable" style="border:0px;" id="log_card">
<thead><tr><td colspan="1">Log</td></tr></thead>
<tr><td><pre id="log_body" class="wgc-log"></pre></td></tr>
<tr><td><input type="button" class="button_gen wgc-act" id="btn_log" value="Refresh" onclick="sendAction({wgcui_action:'refresh'}, 'log');">
<label class="wgc-autolbl"><input type="checkbox" id="auto_chk" onchange="autoChanged();"> Auto-refresh every 30 s</label></td></tr>
</table>
</td>
</tr>
</tbody>
</table>
</td>
</tr>
</table>
</td>
<td width="10" align="center" valign="top">&nbsp;</td>
</tr>
</table>
</form>
<div id="footer"></div>
</body>
</html>
