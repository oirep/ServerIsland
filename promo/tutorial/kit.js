"use strict";
// =====================================================================================
// 教程视频的绘图工具。Tako、刘海形状、壁纸、光标、粒子这些基础画法来自 ../index.html（宣传片），
// 时间单位从"拍"改成了"秒"；卡片、页面、设置窗口按真实 App（--render-preview 的截图）重新画过。
// 坐标：Mac 世界 = 14 寸 MacBook Pro 的屏幕点（1512 × 982），刘海 185 × 32。
// =====================================================================================
const W = 1920, H = 1080;
// ?en：英文版。画面上的文字都写成 T(中文, English)，界面文案和 App 的 L(zh, en) 一致
const EN = new URLSearchParams(location.search).has("en");
const T = (zh, en) => EN ? en : zh;
const FONT = '"PingFang SC", system-ui, -apple-system, sans-serif';
const MONO = '"SF Mono", Menlo, monospace';

// ------------------------------------------------------------------ 工具
const clamp = (x, a = 0, b = 1) => Math.min(b, Math.max(a, x));
const lerp = (a, b, k) => a + (b - a) * k;
const easeOutCubic = k => 1 - Math.pow(1 - k, 3);
const easeInCubic = k => k * k * k;
const easeInOutCubic = k => k < 0.5 ? 4 * k * k * k : 1 - Math.pow(-2 * k + 2, 3) / 2;
const easeOutBack = (k, s = 1.7) => 1 + (s + 1) * Math.pow(k - 1, 3) + s * Math.pow(k - 1, 2);
const easeOutQuint = k => 1 - Math.pow(1 - k, 5);
// 阻尼弹簧（x 单位：秒），0→1 带一点回弹；和 App 的 spring(response 0.44, damping 0.78) 观感接近
function spring(x, stiff = 15, damp = 0.68) {
  if (x <= 0) return 0;
  const w = stiff, z = damp, wd = w * Math.sqrt(1 - z * z);
  return 1 - Math.exp(-z * w * x) * (Math.cos(wd * x) + (z * w / wd) * Math.sin(wd * x));
}
const pr = (t, a, b, e = x => x) => e(clamp((t - a) / (b - a)));
// 窗口：淡入 [a, a+fi]，淡出 [b-fo, b]
const win = (t, a, b, fi = 0.3, fo = 0.3) => Math.min(pr(t, a, a + fi), 1 - pr(t, b - fo, b));
function rnd(i) { const x = Math.sin(i * 127.1 + 311.7) * 43758.5453; return x - Math.floor(x); }
// 打字：在 [t0, t1] 内逐字打出 s
const typed = (s, t, t0, t1) => t < t0 ? "" : [...s].slice(0, Math.ceil([...s].length * pr(t, t0, t1))).join("");

function rr(c, x, y, w, h, r) {
  r = Math.max(0, Math.min(r, w / 2, h / 2));
  c.beginPath();
  c.moveTo(x + r, y); c.lineTo(x + w - r, y); c.quadraticCurveTo(x + w, y, x + w, y + r);
  c.lineTo(x + w, y + h - r); c.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
  c.lineTo(x + r, y + h); c.quadraticCurveTo(x, y + h, x, y + h - r);
  c.lineTo(x, y + r); c.quadraticCurveTo(x, y, x + r, y); c.closePath();
}
function setFont(c, o) { c.font = `${o.weight || 400} ${o.size || 16}px ${o.font || FONT}`; c.letterSpacing = (o.spacing || 0) + "px"; }
function measure(c, s, o = {}) { setFont(c, o); return c.measureText(s).width; }
// o.max：超过这个宽度就在末尾省略
function text(c, s, x, y, o = {}) {
  setFont(c, o);
  c.fillStyle = o.color || "#fff";
  c.textAlign = o.align || "left";
  c.textBaseline = o.base || "alphabetic";
  if (o.max && c.measureText(s).width > o.max) {
    let t = s;
    while (t.length > 1 && c.measureText(t + "…").width > o.max) t = t.slice(0, -1);
    s = t + "…";
  }
  c.fillText(s, x, y);
  return c.measureText(s).width;
}
const COL = {
  mint: "#5BE8B3", cyan: "#5CC2FF", amber: "#FFBF4D", coral: "#FF6E6E", blue: "#73A0FF", violet: "#A88CFF",
  text: "rgba(255,255,255,0.94)", sec: "rgba(255,255,255,0.58)", ter: "rgba(255,255,255,0.36)",
  card: "rgba(255,255,255,0.055)", track: "rgba(255,255,255,0.10)", sep: "rgba(255,255,255,0.08)",
};
const alpha = (hex, a) => { const n = parseInt(hex.slice(1), 16); return `rgba(${n >> 16},${(n >> 8) & 255},${n & 255},${a})`; };
function shade(hex, d) {
  const n = parseInt(hex.slice(1), 16), f = v => clamp(v + d, 0, 255);
  return `rgb(${f(n >> 16)},${f((n >> 8) & 255)},${f(n & 255)})`;
}

// ------------------------------------------------------------------ Tako（与 App 内 Pet.swift 同一张像素网格）
const HEAD = ["......BBBB......", "....BBBBBBBB....", "...BHHBBBBBBB...", "..BHHBBBBBBBBB..", "..BHBBBBBBBBBB..",
  ".BBBBBBBBBBBBBB.", ".BBBBBBBBBBBBBB.", ".BBBBBBBBBBBBBB.", ".BBBBBBBBBBBBBB.", "..SBBBBBBBBBBS.."];
const LEGS_A = [".SBB.BB..BB.BBS.", ".BB..BB..BB..BB.", "BB..BB....BB..BB", "B...B......B...B"];
const LEGS_B = [".SBB.BB..BB.BBS.", "..BB.BB..BB.BB..", "..B..BB..BB..B..", ".BB...B..B...BB."];
const LEGS_T = [".SBBBBB..BBBBBS.", "..BB.BB..BB.BB..", "...B.B....B.B...", "................"];
function takoGrid(mood, tick) {
  let legs = LEGS_A;
  if (mood === "working") legs = tick % 2 ? LEGS_B : LEGS_A;
  if (mood === "happy") legs = tick % 2 ? LEGS_A : LEGS_T;
  const g = HEAD.concat(legs).map(r => r.split(""));
  const put = (r, c, ch) => { if (r >= 0 && r < 14 && c >= 0 && c < 16) g[r][c] = ch; };
  put(8, 3, "C"); put(8, 12, "C");
  const blink = mood === "idle" && tick % 9 === 0;
  if (mood === "happy") {
    for (const c of [4, 11]) { put(6, c, "E"); put(7, c - 1, "E"); put(7, c + 1, "E"); }
    put(8, 7, "M"); put(8, 8, "M"); put(9, 7, "C"); put(9, 8, "C");
  } else if (mood === "sad") {
    for (const c of [4, 11]) { put(5, c - 1, "E"); put(5, c + 1, "E"); put(6, c, "E"); put(7, c - 1, "E"); put(7, c + 1, "E"); }
    put(9, 7, "M"); put(9, 8, "M"); put(8, 6, "M"); put(8, 9, "M");
    put(2, 13, "R"); put(3, 13, "R"); put(3, 14, "R");
  } else if (mood === "waiting") {
    for (const c of [4, 10]) { put(6, c, "S"); put(6, c + 1, "S"); put(7, c, "E"); put(7, c + 1, "E"); }
  } else {
    if (blink) { for (const c of [4, 10]) { put(7, c, "E"); put(7, c + 1, "E"); } }
    else { for (const c of [4, 10]) { put(6, c, "W"); put(6, c + 1, "E"); put(7, c, "E"); put(7, c + 1, "E"); } }
    put(8, 7, "M"); put(8, 8, "M");
  }
  return g;
}
const TAKO_COL = { B: "#5CE6B5", S: "#2EAD87", H: "#BDF9DF", E: "#0A0F1F", W: "#FFFFFF", C: "#FF8FAB", M: "#0A0F1F", R: "#7CC8FF" };
const TAKO_SAD = { B: "#FF8C8C", S: "#CC545C", H: "#FFCCCC" };
// (x, y) = 脚底中心；h = 身高（14 格）；squash > 0 压扁、< 0 拉长
function drawTako(c, x, y, h, mood = "idle", tick = 0, o = {}) {
  const px = h / 14, g = takoGrid(mood, tick);
  const sq = o.squash || 0, sx = 1 + sq * 0.28, sy = 1 - sq * 0.28;
  c.save();
  c.globalAlpha *= (o.alpha ?? 1);
  if (o.shadow !== false) {
    const lift = o.lift || 0;
    c.fillStyle = `rgba(0,0,0,${0.28 * clamp(1 - lift / (h * 3))})`;
    c.beginPath();
    c.ellipse(x, (o.ground ?? y) + px * 0.6, h * 0.5 * (1 - clamp(lift / (h * 4)) * 0.5), h * 0.09, 0, 0, Math.PI * 2);
    c.fill();
  }
  c.translate(x, y);
  if (o.rot) c.rotate(o.rot);
  c.scale(sx * (o.flip ? -1 : 1), sy);
  if (o.glow !== false) { c.shadowColor = mood === "sad" ? "rgba(255,110,110,0.55)" : "rgba(91,230,181,0.5)"; c.shadowBlur = h * 0.35; }
  const pal = mood === "sad" ? Object.assign({}, TAKO_COL, TAKO_SAD) : TAKO_COL;
  for (let r = 0; r < 14; r++) for (let col = 0; col < 16; col++) {
    const ch = g[r][col];
    if (ch === ".") continue;
    c.fillStyle = pal[ch];
    c.fillRect((col - 8) * px, (r - 14) * px, px + 0.6, px + 0.6);
  }
  c.restore();
  // 排队时头顶的 z
  if (mood === "waiting" && o.zzz !== false) {
    const k = (tick % 4) / 4;
    c.save(); c.globalAlpha *= (o.alpha ?? 1) * (1 - k * 0.6);
    text(c, "z", x + h * 0.42 + k * h * 0.12, y - h * 1.0 - k * h * 0.25, { size: h * 0.36, weight: 800, color: COL.amber });
    c.restore();
  }
}
// 抛物线跳跃：在 [t0, t1] 秒从 p0 跳到 p1，返回 {x, y, lift, squash, ground}
function hop(t, t0, t1, p0, p1, height) {
  const k = clamp((t - t0) / (t1 - t0));
  const x = lerp(p0[0], p1[0], k), base = lerp(p0[1], p1[1], k);
  const y = base - Math.sin(k * Math.PI) * height;
  let squash = 0;
  const pre = (t0 - t) / 0.12, post = (t - t1) / 0.25;
  if (t < t0 && pre < 1) squash = 0.6 * (1 - pre);
  else if (t > t1 && post < 1) squash = 0.9 * Math.exp(-post * 3) * Math.cos(post * 9);
  else if (t >= t0 && t <= t1) squash = -0.35 * Math.sin(k * Math.PI);
  return { x, y, lift: base - y, squash, ground: base };
}

// 5x7 像素字（ServerIsland 字样）
const PFONT = {
  S: [".####", "#....", "#....", ".###.", "....#", "....#", "####."], e: [".....", ".....", ".###.", "#...#", "#####", "#....", ".###."],
  r: [".....", ".....", "#.##.", "##..#", "#....", "#....", "#...."], v: [".....", ".....", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
  I: ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "#####"], s: [".....", ".....", ".####", "#....", ".###.", "....#", "####."],
  l: [".##..", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."], a: [".....", ".....", ".###.", "....#", ".####", "#...#", ".####"],
  n: [".....", ".....", "#.##.", "##..#", "#...#", "#...#", "#...#"], d: ["....#", "....#", ".##.#", "#..##", "#...#", "#...#", ".####"],
};
function wordCells(word) {
  const cells = []; let x = 0;
  for (const ch of word) {
    const g = PFONT[ch];
    const cols = [0, 1, 2, 3, 4].filter(c => g.some(r => r[c] === "#"));
    const lo = Math.min(...cols), hi = Math.max(...cols);
    g.forEach((row, r) => { for (let c = lo; c <= hi; c++) if (row[c] === "#") cells.push([x + c - lo, r]); });
    x += hi - lo + 2;
  }
  return { cells, cols: x - 1 };
}
const WORD = wordCells("ServerIsland");
function drawWord(c, cx, cy, cell, k, a = 1, seed = 1) {
  const w = WORD.cols * cell, x0 = cx - w / 2;
  const grad = c.createLinearGradient(x0, 0, x0 + w, 0);
  grad.addColorStop(0, COL.mint); grad.addColorStop(1, "#7CCBFF");
  c.save();
  const a0 = c.globalAlpha * a;
  c.fillStyle = grad;
  c.shadowColor = "rgba(91,230,181,0.45)"; c.shadowBlur = cell * 1.6;
  WORD.cells.forEach(([col, row], i) => {
    const d = rnd(i * 3 + seed), kk = clamp((k - d * 0.45) / 0.55);
    if (kk <= 0) return;
    const e = easeOutBack(kk, 1.4);
    const tx = x0 + col * cell, ty = cy + (row - 3.5) * cell;
    const sx = cx + (rnd(i * 7 + seed) - 0.5) * W * 1.1, sy = cy + (rnd(i * 11 + seed) - 0.5) * H * 0.9;
    c.globalAlpha = a0 * clamp(kk * 3);
    c.fillRect(lerp(sx, tx, e), lerp(sy, ty, e), cell + 0.5, cell + 0.5);
  });
  c.restore();
}

// ------------------------------------------------------------------ 背景：夜空 + 像素海浪（与 logo 同风格）
function drawNight(c, t, a = 1) {
  c.save();
  c.globalAlpha *= a;
  const g = c.createLinearGradient(0, 0, 0, H);
  g.addColorStop(0, "#121836"); g.addColorStop(0.6, "#112B4A"); g.addColorStop(1, "#0D4A57");
  c.fillStyle = g; c.fillRect(0, 0, W, H);
  const rg = c.createRadialGradient(W / 2, H * 0.55, 0, W / 2, H * 0.55, H * 0.75);
  rg.addColorStop(0, "rgba(91,230,181,0.22)"); rg.addColorStop(1, "rgba(91,230,181,0)");
  c.fillStyle = rg; c.fillRect(0, 0, W, H);
  const a0 = c.globalAlpha;
  for (let i = 0; i < 70; i++) {
    const x = rnd(i) * W, y = rnd(i + 99) * H * 0.7, sz = 2 + Math.floor(rnd(i + 7) * 3) * 2;
    c.globalAlpha = a0 * (0.35 + 0.65 * (0.5 + 0.5 * Math.sin(t * 3.2 + i * 1.7))) * 0.7;
    c.fillStyle = "#fff"; c.fillRect(Math.round(x), Math.round(y), sz, sz);
  }
  c.globalAlpha = a0;
  for (let row = 0; row < 3; row++) {
    const y0 = H - 150 + row * 44, off = (t * (row + 1) * 18) % 60;
    for (let x = -60; x < W + 60; x += 60) {
      const k = Math.floor((x + off * (row % 2 ? -1 : 1)) / 60);
      const dy = (Math.abs(k) % 4 === 1 || Math.abs(k) % 4 === 2) ? 14 : 0;
      c.fillStyle = row === 0 ? "rgba(127,216,255,0.30)" : row === 1 ? "rgba(91,230,181,0.18)" : "rgba(91,230,181,0.10)";
      rr(c, x + (row % 2 ? -off : off), y0 + dy, 40, 16, 3); c.fill();
    }
  }
  c.restore();
}

// ------------------------------------------------------------------ Mac 世界
const SW = 1512, SH = 982, MENU = 32, NOTCH_W = 185, MID = SW / 2;
const LOGO = document.getElementById("logo");
const WALL = {};
function buildWallpaper(kind = "mac") {
  const sc = 2.2, oc = document.createElement("canvas");
  oc.width = SW * sc; oc.height = SH * sc;
  const c = oc.getContext("2d"); c.scale(sc, sc);
  if (kind === "mac") {
    const g = c.createLinearGradient(0, 0, SW * 0.3, SH);
    g.addColorStop(0, "#3C4C8F"); g.addColorStop(0.45, "#8D6FB1"); g.addColorStop(0.75, "#D99A9C"); g.addColorStop(1, "#F2C89A");
    c.fillStyle = g; c.fillRect(0, 0, SW, SH);
    for (const [x, y, r, col] of [[300, 300, 380, "rgba(90,130,255,0.45)"], [1200, 260, 420, "rgba(255,150,200,0.35)"], [900, 800, 460, "rgba(255,200,140,0.40)"], [200, 850, 300, "rgba(120,90,200,0.35)"]]) {
      const rg = c.createRadialGradient(x, y, 0, x, y, r);
      rg.addColorStop(0, col); rg.addColorStop(1, "rgba(0,0,0,0)");
      c.fillStyle = rg; c.fillRect(0, 0, SW, SH);
    }
  } else {
    // Windows 风格：深蓝底 + 柔光花瓣
    const g = c.createLinearGradient(0, 0, 0, SH);
    g.addColorStop(0, "#0B2A5B"); g.addColorStop(1, "#06152F");
    c.fillStyle = g; c.fillRect(0, 0, SW, SH);
    for (let i = 0; i < 5; i++) {
      c.save(); c.translate(SW * 0.55, SH * 0.62); c.rotate(-0.9 + i * 0.36);
      const lg = c.createLinearGradient(0, 0, 640, 0);
      lg.addColorStop(0, "rgba(90,170,255,0.55)"); lg.addColorStop(1, "rgba(60,120,255,0)");
      c.fillStyle = lg; c.beginPath(); c.ellipse(320, 0, 330, 70, 0, 0, Math.PI * 2); c.fill();
      c.restore();
    }
  }
  WALL[kind] = oc;
}

const camKeys = (t, keys) => {
  // keys: [[秒, {x, y, z}], ...]；相邻关键帧之间 easeInOutCubic，缩放在对数空间插值
  if (t <= keys[0][0]) return keys[0][1];
  for (let i = 1; i < keys.length; i++) {
    if (t <= keys[i][0]) {
      const [t0, a] = keys[i - 1], [t1, b] = keys[i];
      const k = easeInOutCubic((t - t0) / Math.max(1e-6, t1 - t0));
      return { x: lerp(a.x, b.x, k), y: lerp(a.y, b.y, k), z: Math.exp(lerp(Math.log(a.z), Math.log(b.z), k)) };
    }
  }
  return keys[keys.length - 1][1];
};
function withCamera(c, cam, fn) {
  c.save();
  c.translate(W / 2, H / 2); c.scale(cam.z, cam.z); c.translate(-cam.x, -cam.y);
  fn();
  c.restore();
}
const CAM_FULL = { x: MID, y: SH / 2 + 30, z: 0.98 };

function drawLaptop(c) {
  c.save();
  const baseG = c.createLinearGradient(0, SH + 20, 0, SH + 62);
  baseG.addColorStop(0, "#C9CDD4"); baseG.addColorStop(1, "#8E939B");
  c.fillStyle = baseG;
  c.beginPath();
  c.moveTo(-120, SH + 24); c.lineTo(SW + 120, SH + 24); c.lineTo(SW + 60, SH + 58); c.lineTo(-60, SH + 58); c.closePath(); c.fill();
  c.fillStyle = "#9CA1A9"; rr(c, MID - 110, SH + 24, 220, 10, 5); c.fill();
  c.fillStyle = "#0B0B0D"; rr(c, -22, -22, SW + 44, SH + 46, 30); c.fill();
  c.strokeStyle = "rgba(255,255,255,0.08)"; c.lineWidth = 2; rr(c, -22, -22, SW + 44, SH + 46, 30); c.stroke();
  c.restore();
}

function drawDesktop(c, t, o = {}) {
  c.save();
  rr(c, 0, 0, SW, SH, 10); c.clip();
  c.drawImage(WALL.mac, 0, 0, SW, SH);
  // Dock
  const dw = 640, dh = 66, dx = MID - dw / 2, dy = SH - 84;
  c.fillStyle = "rgba(255,255,255,0.22)"; rr(c, dx, dy, dw, dh, 20); c.fill();
  c.strokeStyle = "rgba(255,255,255,0.25)"; c.lineWidth = 1; rr(c, dx, dy, dw, dh, 20); c.stroke();
  ["#4AA3FF", "#FF7A59", "#2BD17E", "#FFC53D", "#9B7BFF", "logo", "#3E3E46", "#FF5EA8", "#58D5FF"].forEach((col, i) => {
    const ix = dx + 18 + i * 68, iy = dy + 9;
    if (col === "logo") { if (LOGO.complete) c.drawImage(LOGO, ix - 6, iy - 6, 60, 60); }
    else {
      const ig = c.createLinearGradient(0, iy, 0, iy + 48); ig.addColorStop(0, col); ig.addColorStop(1, shade(col, -40));
      c.fillStyle = ig; rr(c, ix, iy, 48, 48, 12); c.fill();
    }
  });
  if (o.below) o.below();
  // 菜单栏
  c.fillStyle = "rgba(255,255,255,0.20)"; c.fillRect(0, 0, SW, MENU);
  text(c, "", 22, 22, { size: 17 });
  const app = o.app || "Finder";
  let mx = 52 + text(c, app, 52, 22, { size: 14, weight: 700 }) + 22;
  (o.menus || [T("文件", "File"), T("编辑", "Edit"), T("显示", "View"), T("前往", "Go"), T("窗口", "Window"), T("帮助", "Help")]).forEach(s => { mx += text(c, s, mx, 22, { size: 14 }) + 24; });
  text(c, T("10月19日 周一  14:26", "Mon Oct 19  14:26"), SW - 20, 22, { size: 14, align: "right" });
  drawTako(c, SW - 196, 25, 15, "idle", 1, { shadow: false, glow: false });
  c.save(); c.fillStyle = "#fff"; c.globalAlpha *= 0.9;
  [SW - 236, SW - 268].forEach(x => { rr(c, x - 9, 9, 18, 14, 3); c.fill(); });
  c.restore();
  c.restore();
}

// ------------------------------------------------------------------ 线条图标（意思与 SF Symbols / Icons.cs 一致）
function icon(c, name, x, y, s = 12, col = COL.sec, o = {}) {
  c.save();
  c.translate(x, y); c.scale(s / 24, s / 24);
  c.strokeStyle = col; c.fillStyle = col; c.lineWidth = o.lw || 2.2; c.lineCap = "round"; c.lineJoin = "round";
  const P = (pts, close) => { c.beginPath(); pts.forEach(([a, b], i) => i ? c.lineTo(a - 12, b - 12) : c.moveTo(a - 12, b - 12)); if (close) c.closePath(); };
  const circ = (a, b, r, fill) => { c.beginPath(); c.arc(a - 12, b - 12, r, 0, Math.PI * 2); fill ? c.fill() : c.stroke(); };
  switch (name) {
    case "grid": for (let i = 0; i < 3; i++) for (let j = 0; j < 3; j++) { rr(c, -10 + i * 7.3, -10 + j * 7.3, 5.6, 5.6, 1.2); c.fill(); } break;
    case "terminal": rr(c, -10, -8, 20, 16, 3); c.stroke(); P([[7, 10], [10, 12.5], [7, 15]]); c.stroke(); P([[12, 15], [16, 15]]); c.stroke(); break;
    case "history": c.beginPath(); c.arc(0, 0, 9, Math.PI * 0.95, Math.PI * 2.75); c.stroke(); P([[1, 9], [3, 13], [7, 11]]); c.stroke(); P([[12, 7], [12, 12], [15.5, 14]]); c.stroke(); break;
    case "pause": c.fillRect(-6, -8, 4, 16); c.fillRect(2, -8, 4, 16); break;
    case "play": P([[7, 4], [19, 12], [7, 20]], true); c.fill(); break;
    case "bell": c.beginPath(); c.moveTo(-8, 5); c.quadraticCurveTo(-6, 2, -6, -2); c.quadraticCurveTo(-6, -9, 0, -9); c.quadraticCurveTo(6, -9, 6, -2); c.quadraticCurveTo(6, 2, 8, 5); c.closePath(); c.fill(); circ(12, 20, 2.4, true); break;
    case "bellSlash": icon(c, "bell", 0, 0, 24, col); c.strokeStyle = col; c.lineWidth = 2.4; P([[3, 3], [21, 21]]); c.stroke(); break;
    case "eye": c.beginPath(); c.moveTo(-11, 0); c.quadraticCurveTo(0, -11, 11, 0); c.quadraticCurveTo(0, 11, -11, 0); c.closePath(); c.stroke(); circ(12, 12, 3.2, true); break;
    case "eyeFill": c.beginPath(); c.moveTo(-11, 0); c.quadraticCurveTo(0, -11, 11, 0); c.quadraticCurveTo(0, 11, -11, 0); c.closePath(); c.fill(); c.fillStyle = "#000"; circ(12, 12, 3.2, true); break;
    case "gear": for (let i = 0; i < 8; i++) { c.save(); c.rotate(i * Math.PI / 4); c.fillRect(-2.5, -11, 5, 6); c.restore(); } circ(12, 12, 7.2, true); c.fillStyle = "#000"; circ(12, 12, 3, true); break;
    case "pin": P([[9, 3], [15, 3]]); c.stroke(); P([[10, 3], [9.5, 10], [6.5, 13], [17.5, 13], [14.5, 10], [14, 3]]); c.stroke(); P([[12, 13], [12, 21]]); c.stroke(); break;
    case "refresh": c.beginPath(); c.arc(0, 0, 8, -Math.PI * 0.35, Math.PI * 1.45); c.stroke(); P([[15.5, 2.5], [17.2, 6.8], [12.6, 7.6]]); c.stroke(); break;
    case "back": P([[14.5, 6], [8.5, 12], [14.5, 18]]); c.stroke(); break;
    case "copy": rr(c, -7, -4, 11, 14, 2.5); c.stroke(); P([[9, 4], [16, 4], [16, 15]]); c.stroke(); break;
    case "folder": c.beginPath(); c.moveTo(-10, -6); c.lineTo(-4, -6); c.lineTo(-2, -3); c.lineTo(10, -3); c.lineTo(10, 8); c.lineTo(-10, 8); c.closePath(); c.stroke(); break;
    case "bolt": P([[13.5, 2], [6, 13.5], [11.5, 13.5], [10.5, 22], [18, 10.5], [12.5, 10.5]], true); c.fill(); break;
    case "hourglass": P([[6, 3], [18, 3], [6, 21], [18, 21]], true); c.stroke(); break;
    case "check": P([[5, 12.5], [10, 17.5], [19, 6.5]]); c.stroke(); break;
    case "xmark": P([[6, 6], [18, 18]]); c.stroke(); P([[18, 6], [6, 18]]); c.stroke(); break;
    case "minus": P([[6, 12], [18, 12]]); c.stroke(); break;
    case "clock": circ(12, 12, 9); P([[12, 7], [12, 12], [15.5, 14]]); c.stroke(); break;
    case "plus": circ(12, 12, 9, true); c.strokeStyle = o.inner || "#000"; P([[12, 7.5], [12, 16.5]]); c.stroke(); P([[7.5, 12], [16.5, 12]]); c.stroke(); break;
    case "power": c.beginPath(); c.arc(0, 0, 8, -Math.PI * 0.3, Math.PI * 1.3); c.stroke(); P([[12, 2.5], [12, 11]]); c.stroke(); break;
    case "hand": c.beginPath(); c.moveTo(-3, 9); c.lineTo(-8, 2); c.quadraticCurveTo(-9, -1, -6, 0); c.lineTo(-3, 3); c.lineTo(-3, -9); c.quadraticCurveTo(0, -11, 0, -8); c.lineTo(0, -2); c.lineTo(8, 0); c.quadraticCurveTo(10, 1, 9, 5); c.lineTo(7, 9); c.closePath(); c.stroke(); break;
    case "warn": P([[12, 3], [22, 20], [2, 20]], true); c.fill(); c.fillStyle = "#000"; c.fillRect(-1.2, -3, 2.4, 6.5); c.fillRect(-1.2, 5.2, 2.4, 2.4); break;
    case "download": circ(12, 12, 10, true); c.strokeStyle = "#fff"; P([[12, 6.5], [12, 16]]); c.stroke(); P([[8, 12.5], [12, 16.5], [16, 12.5]]); c.stroke(); break;
    case "key": circ(8, 12, 4.5); P([[12.5, 12], [21, 12]]); c.stroke(); P([[18, 12], [18, 15.5]]); c.stroke(); break;
    case "atom": for (let a = 0; a < 3; a++) { c.beginPath(); c.ellipse(0, 0, 10, 4, a * Math.PI / 3, 0, Math.PI * 2); c.stroke(); } circ(12, 12, 2.3, true); break;
    case "stack": { const a0 = c.globalAlpha; for (let i = 2; i >= 0; i--) { c.globalAlpha = a0 * (i === 0 ? 1 : 0.65); P([[2, 9 + i * 4], [12, 4 + i * 4], [22, 9 + i * 4], [12, 14 + i * 4]], true); c.fill(); } c.globalAlpha = a0; break; }
    case "server": rr(c, -10, -9, 20, 8, 2); c.stroke(); rr(c, -10, 1, 20, 8, 2); c.stroke(); circ(7, 7, 1.3, true); circ(7, 17, 1.3, true); break;
    case "wand": P([[4, 20], [16, 8]]); c.stroke(); P([[17, 2], [17, 6]]); c.stroke(); P([[15, 4], [19, 4]]); c.stroke(); P([[21, 9], [21, 12]]); c.stroke(); break;
  }
  c.restore();
}
function iconCircle(c, x, y, col, glyph, r = 11) {
  c.fillStyle = alpha(col, 0.16); c.beginPath(); c.arc(x, y, r, 0, 7); c.fill();
  icon(c, glyph, x, y, r * 1.15, col, { lw: 2 });
}

// ------------------------------------------------------------------ 灵动岛
const SPEC = {
  hidden: { w: NOTCH_W, h: MENU, ear: 0, bot: 8 },
  collapsed: { w: NOTCH_W + 2 * 62, h: MENU, ear: 6, bot: 10 },
  toast: { w: 445, h: MENU + 60, ear: 10, bot: 22 },
};
const panelSpec = (h, w = 668) => ({ w, h, ear: 14, bot: 26 });
// keys: [[秒, spec 或名字]]，状态之间用弹簧过渡
function islandSpec(t, keys) {
  const get = s => typeof s === "string" ? SPEC[s] : s;
  let i = 0; for (let j = 0; j < keys.length; j++) if (t >= keys[j][0]) i = j;
  const from = get(keys[Math.max(0, i - 1)][1]), to = get(keys[i][1]);
  const k = i === 0 ? 1 : spring(t - keys[i][0]);
  const name = typeof keys[i][1] === "string" ? keys[i][1] : (keys[i][1].name || "panel");
  return { w: lerp(from.w, to.w, k), h: lerp(from.h, to.h, k), ear: lerp(from.ear, to.ear, k), bot: lerp(from.bot, to.bot, k), name, since: t - keys[i][0], k };
}
function islandPath(c, s, cx = MID) {
  const x0 = cx - s.w / 2, tt = s.ear, b = Math.min(s.bot, (s.w - 2 * tt) / 2, s.h - tt), x1 = cx + s.w / 2, y1 = s.h;
  c.beginPath();
  c.moveTo(x0, 0);
  c.quadraticCurveTo(x0 + tt, 0, x0 + tt, tt);
  c.lineTo(x0 + tt, y1 - b); c.quadraticCurveTo(x0 + tt, y1, x0 + tt + b, y1);
  c.lineTo(x1 - tt - b, y1); c.quadraticCurveTo(x1 - tt, y1, x1 - tt, y1 - b);
  c.lineTo(x1 - tt, tt); c.quadraticCurveTo(x1 - tt, 0, x1, 0);
  c.closePath();
}
function drawIsland(c, s, content, cx = MID) {
  c.save();
  if (s.h > MENU + 4) { c.shadowColor = "rgba(0,0,0,0.55)"; c.shadowBlur = 40; c.shadowOffsetY = 14; }
  islandPath(c, s, cx); c.fillStyle = "#000"; c.fill();
  c.restore();
  c.save(); islandPath(c, s, cx); c.clip();
  if (content) content(cx - s.w / 2 + s.ear, s.w - 2 * s.ear, s);
  c.restore();
}

// ------------------------------------------------------------------ 刘海里的小部件
function bar(c, x, y, w, k, fill, h = 4) {
  c.fillStyle = COL.track; rr(c, x, y, w, h, h / 2); c.fill();
  if (k > 0) {
    if (fill === "time") { const g = c.createLinearGradient(x, 0, x + w, 0); g.addColorStop(0, "rgba(255,255,255,0.39)"); g.addColorStop(1, "rgba(255,255,255,0.6)"); c.fillStyle = g; }
    else if (typeof fill === "string") c.fillStyle = fill;
    else { const g = c.createLinearGradient(x, 0, x + w, 0); g.addColorStop(0, COL.mint); g.addColorStop(1, COL.cyan); c.fillStyle = g; }
    rr(c, x, y, Math.max(h, w * clamp(k)), h, h / 2); c.fill();
  }
}
function ring(c, x, y, r, k, lw = 2.4) {
  c.lineWidth = lw; c.strokeStyle = COL.track; c.beginPath(); c.arc(x, y, r, 0, Math.PI * 2); c.stroke();
  const g = c.createLinearGradient(x - r, y, x + r, y); g.addColorStop(0, COL.mint); g.addColorStop(1, COL.cyan);
  c.strokeStyle = g; c.lineCap = "round"; c.beginPath(); c.arc(x, y, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * clamp(k)); c.stroke(); c.lineCap = "butt";
}
function kindBadge(c, s, x, y) {
  const col = s === "DIRECT" ? COL.cyan : COL.violet;
  const w = measure(c, s, { size: 8, weight: 700, spacing: 0.6 }) + 10;
  c.fillStyle = alpha(col, 0.14); rr(c, x, y - 9, w, 13, 6.5); c.fill();
  text(c, s, x + 5, y + 1, { size: 8, weight: 700, color: col, spacing: 0.6 });
  return w;
}
// 运行 / 排队数的小胶囊
function countsChip(c, x, cy, run, pend) {
  const parts = [];
  if (run) parts.push(["bolt", run, COL.mint]);
  if (pend) parts.push(["hourglass", pend, COL.amber]);
  if (!parts.length) return 0;
  const ws = parts.map(([, v]) => 11 + measure(c, String(v), { size: 10.5, weight: 700 }));
  const w = ws.reduce((a, b) => a + b, 0) + (parts.length - 1) * 7 + 14;
  c.fillStyle = "rgba(255,255,255,0.07)"; rr(c, x, cy - 8, w, 16, 8); c.fill();
  let px = x + 7;
  parts.forEach(([ic, v, col], i) => { icon(c, ic, px + 4, cy, 9, col); text(c, String(v), px + 10, cy + 3.8, { size: 10.5, weight: 700, color: col }); px += ws[i] + 7; });
  return w;
}
function pill(c, x, cy, label, o = {}) {
  const w = measure(c, label, { size: o.size || 10, weight: 600 }) + (o.icon ? 26 : 14);
  c.fillStyle = o.bg || "rgba(255,255,255,0.07)"; rr(c, x, cy - 9, w, 18, 9); c.fill();
  if (o.stroke) { c.strokeStyle = o.stroke; c.lineWidth = 0.8; rr(c, x, cy - 9, w, 18, 9); c.stroke(); }
  if (o.icon) icon(c, o.icon, x + 11, cy, 10, o.color || COL.sec);
  text(c, label, x + (o.icon ? 19 : 7), cy + 3.6, { size: o.size || 10, weight: 600, color: o.color || COL.sec });
  return w;
}
function gpuCells(c, x, cy, cells) {
  // cells: 每张卡的利用率（0..1）；闲置的卡是灰色
  cells.forEach((u, i) => {
    const cx = x + i * 11;
    c.fillStyle = "rgba(255,255,255,0.10)"; rr(c, cx, cy - 6, 8, 12, 2.5); c.fill();
    if (u > 0.05) { const g = c.createLinearGradient(0, cy + 6, 0, cy - 6); g.addColorStop(0, COL.mint); g.addColorStop(1, COL.cyan); c.fillStyle = g; rr(c, cx, cy - 6, 8, 12, 2.5); c.fill(); }
  });
  return cells.length * 11;
}

// 卡片高度（与 IslandLayout 一致：pad 12、header 20、metrics 10+16、jobRow 34、jobGap 6）
function cardHeight(card) {
  let h = 12 * 2 + 20;
  if (card.metrics) h += 10 + 16;
  if (card.banner) h += 10 + 26;
  if (card.jobs.length) h += 10 + card.jobs.length * 34 + (card.jobs.length - 1) * 6;
  if (card.more) h += 20;
  return h;
}
// 一张服务器卡片。card = {name, kind, run, pend, meta, metrics:[[lab,k,val]], gpus:[...], jobs:[...], more, muted, paused, hl:{icon:name}}
// job = {icon, col, name, id, idCol, right, rightCol, detail, detailCol, k, fill, seg:[done, failed, running], segText, pending, warn, hl, watch}
function drawCard(c, x, y, w, card, t, o = {}) {
  const pad = 12, h = cardHeight(card);
  c.save();
  c.fillStyle = "rgba(255,255,255,0.055)"; rr(c, x, y, w, h, 16); c.fill();
  c.strokeStyle = "rgba(255,255,255,0.09)"; c.lineWidth = 0.6; rr(c, x, y, w, h, 16); c.stroke();
  let cy = y + pad + 10;
  const dot = card.paused ? COL.amber : card.offline ? COL.amber : COL.mint;
  c.fillStyle = dot; c.shadowColor = dot; c.shadowBlur = 5; c.beginPath(); c.arc(x + pad + 4, cy, 3.3, 0, 7); c.fill(); c.shadowBlur = 0;
  let nx = x + pad + 14;
  nx += text(c, card.name, nx, cy + 4.6, { size: 13, weight: 600 }) + 8;
  nx += kindBadge(c, card.kind, nx, cy + 3.5) + 8;
  countsChip(c, nx, cy, card.run, card.pend);
  // 右侧：图标按钮、间隔、暂停、静音、时间
  let rx = x + w - pad;
  if (card.meta !== "") {
    rx -= text(c, card.meta || "110ms", rx, cy + 3.8, { size: 10, color: COL.ter, align: "right" }) + 6;
    rx -= text(c, card.ago || T("刚刚", "just now"), rx, cy + 3.8, { size: 10, color: COL.ter, align: "right" }) + 12;
  }
  const btns = [];
  btns.push(card.muted ? ["bellSlash", COL.amber] : ["bell", COL.sec]);
  btns.push(card.paused ? ["play", COL.amber] : ["pause", COL.sec]);
  btns.push(["pill", card.paused ? T("暂停", "paused") : "1m"]);
  btns.push(["history", COL.sec]); btns.push(["terminal", COL.sec]);
  btns.push(card.kind === "DIRECT" ? ["eye", COL.sec] : card.kind === "SLURM" ? ["grid", COL.sec] : null);
  card._btn = {};
  for (const b of btns) {
    if (!b) continue;
    if (b[0] === "pill") {
      const pw = measure(c, b[1], { size: 10, weight: 600 }) + 14;
      rx -= pw;
      c.strokeStyle = "rgba(255,255,255,0.14)"; c.lineWidth = 0.8; rr(c, rx, cy - 8, pw, 16, 8); c.stroke();
      text(c, b[1], rx + pw / 2, cy + 3.6, { size: 10, weight: 600, color: card.paused ? COL.amber : COL.sec, align: "center" });
      card._btn.pill = [rx + pw / 2, cy];
      rx -= 8; continue;
    }
    rx -= 10;
    const hl = card.hl && card.hl[b[0]];
    if (hl) { c.fillStyle = `rgba(255,255,255,${0.16 * hl})`; c.beginPath(); c.arc(rx, cy, 10, 0, 7); c.fill(); }
    icon(c, b[0], rx, cy, b[0] === "pause" ? 9 : 11, hl ? lerpCol(b[1], 1, hl) : b[1]);
    card._btn[b[0].replace("Slash", "").replace("play", "pause")] = [rx, cy];
    rx -= 12;
  }
  cy = y + pad + 20;
  if (card.metrics) {
    cy += 10;
    const my = cy + 8;
    let mx = x + pad + 2;
    for (const [lab, k, val] of card.metrics) {
      mx += text(c, lab, mx, my + 3.6, { size: 9.5, weight: 600, color: COL.ter }) + 7;
      if (lab === "GPU") { mx += gpuCells(c, mx, my, card.gpus) + 6; }
      else { bar(c, mx, my - 2, 44, k, k > 0.85 ? COL.coral : k > 0.6 ? COL.amber : COL.mint); mx += 50; }
      mx += text(c, val, mx, my + 3.8, { size: 10.5, weight: 500, color: COL.sec }) + 18;
    }
    cy += 16;
  }
  if (card.banner) {
    cy += 10;
    c.fillStyle = alpha(COL.amber, 0.10); rr(c, x + pad, cy, w - pad * 2, 26, 9); c.fill();
    icon(c, "pause", x + pad + 14, cy + 13, 9, COL.amber);
    text(c, card.banner, x + pad + 26, cy + 17, { size: 10.5, weight: 500, color: COL.amber });
    pill(c, x + w - pad - 52, cy + 13, T("恢复", "Resume"), { icon: "play", color: COL.amber, bg: alpha(COL.amber, 0.14) });
    pill(c, x + w - pad - 128, cy + 13, T("刷新一次", "Refresh Once"), { icon: "refresh", color: COL.sec });
    cy += 26;
  }
  if (card.jobs.length) cy += 10;
  card._rows = [];
  for (const j of card.jobs) {
    card._rows.push(cy);
    if (j.hl) { c.fillStyle = `rgba(255,255,255,${0.08 * j.hl})`; rr(c, x + 6, cy - 3, w - 12, 40, 9); c.fill(); }
    iconCircle(c, x + pad + 11, cy + 17, j.col, j.icon);
    const lx = x + pad + 30;
    let nw = text(c, j.name, lx, cy + 12, { size: 12, weight: 500, max: w * 0.42 });
    if (j.watch) { icon(c, "eyeFill", lx + nw + 10, cy + 8, 11, COL.cyan); nw += 16; }
    if (j.id) text(c, j.id, lx + nw + 6, cy + 12, { size: 9.5, font: MONO, color: j.idCol || COL.ter, weight: j.idCol ? 600 : 400 });
    text(c, j.right, x + w - pad, cy + 12, { size: 10.5, weight: 600, color: j.rightCol || COL.sec, align: "right" });
    const bw = Math.round(w * 0.55), bx = lx, by = cy + 22;
    if (j.pending) {
      let px = lx;
      if (j.warn) { icon(c, "warn", lx + 5, cy + 26, 10, COL.coral); px += 13; }
      text(c, j.pending, px, cy + 30, { size: 10, weight: j.warn ? 600 : 400, color: j.warn ? COL.coral : "rgba(255,191,77,0.85)" });
    } else if (j.seg) {
      c.fillStyle = COL.track; rr(c, bx, by, bw, 4, 2); c.fill();
      c.save(); rr(c, bx, by, bw, 4, 2); c.clip();
      const [d, f, r] = j.seg;
      c.fillStyle = COL.mint; c.fillRect(bx, by, bw * d, 4); c.fillStyle = COL.coral; c.fillRect(bx + bw * d + 1, by, bw * f, 4);
      c.fillStyle = "rgba(92,194,255,0.6)"; c.fillRect(bx + bw * (d + f) + 2, by, bw * r, 4); c.restore();
      let rxx = x + w - pad;
      for (let i = j.segText.length - 1; i >= 0; i--) {
        const [str, col] = j.segText[i];
        rxx -= text(c, str, rxx, cy + 30, { size: 10, color: col, align: "right" });
        if (i > 0) rxx -= text(c, " · ", rxx, cy + 30, { size: 10, color: COL.ter, align: "right" });
      }
    } else {
      bar(c, bx, by, bw, j.k, j.fill || null);
      text(c, j.detail, x + w - pad, cy + 30, { size: 10, color: j.detailCol || COL.ter, align: "right", max: w - bw - pad * 2 - 40 });
    }
    cy += 40;
  }
  if (card.more) text(c, card.more, x + pad + 30, cy + 8, { size: 10.5, weight: 600, color: COL.cyan });
  c.restore();
  return h;
}
function lerpCol(col) { return col === COL.sec ? "#fff" : col; }
function drawIdleRow(c, x, y, w, hosts, o = {}) {
  c.fillStyle = "rgba(255,255,255,0.04)"; rr(c, x, y, w, 36, 14); c.fill();
  c.strokeStyle = "rgba(255,255,255,0.08)"; c.lineWidth = 0.6; rr(c, x, y, w, 36, 14); c.stroke();
  text(c, "☾", x + 14, y + 23, { size: 12, color: COL.ter });
  let px = x + 32 + text(c, T(`${hosts.length} 台空闲`, `${hosts.length} idle`), x + 32, y + 22.5, { size: 11, weight: 600, color: COL.sec }) + 12;
  for (const n of hosts) {
    c.fillStyle = COL.mint; c.beginPath(); c.arc(px + 2.5, y + 18.5, 2.5, 0, 7); c.fill();
    px += 9 + text(c, n, px + 9, y + 22.5, { size: 11, color: COL.ter }) + 12;
  }
  text(c, T("展开 ⌄", "Show ⌄"), x + w - 14, y + 22.5, { size: 10, weight: 500, color: COL.cyan, align: "right" });
}
// 面板顶部
function islandHeader(c, x, w, t, o = {}) {
  drawTako(c, x + 14, 27, 17, o.mood || "working", Math.floor(t * 4), { shadow: false });
  let hx = x + 30 + text(c, "ServerIsland", x + 30, 21.5, { size: 12.5, weight: 600 }) + 10;
  icon(c, "bolt", hx + 4, 17, 10, COL.mint); hx += 11 + text(c, String(o.run ?? 12), hx + 11, 21.5, { size: 11.5, weight: 700, color: COL.mint }) + 8;
  icon(c, "hourglass", hx + 4, 17, 9, COL.amber); text(c, String(o.pend ?? 20), hx + 11, 21.5, { size: 11.5, weight: 700, color: COL.amber });
  const rx = x + w;
  [["gear", 0], ["refresh", 32], ["pin", 64]].forEach(([g, d]) => {
    c.fillStyle = "rgba(255,255,255,0.08)"; c.beginPath(); c.arc(rx - d - 12, 17, 12, 0, 7); c.fill();
    icon(c, g, rx - d - 12, 17, 12, COL.sec);
  });
  c.fillStyle = "rgba(255,255,255,0.08)"; rr(c, rx - 140, 5, 46, 24, 12); c.fill();
  icon(c, "clock", rx - 128, 17, 10, COL.sec);
  text(c, "1m", rx - 120, 21, { size: 10.5, weight: 600, color: COL.sec });
}
// 收起状态的两翼（左：Tako + 运行数；右：领先任务的进度环）
function drawWings(c, t, o = {}) {
  const cy = MENU / 2;
  drawTako(c, MID - NOTCH_W / 2 - 42, cy + 9, 17, o.mood || "working", Math.floor(t * 4), { shadow: false, zzz: false });
  text(c, String(o.run ?? 12), MID - NOTCH_W / 2 - 22, cy + 5, { size: 13, weight: 600 });
  const k = o.k ?? 0.62;
  ring(c, MID + NOTCH_W / 2 + 14, cy, 6.5, k);
  text(c, Math.round(k * 100) + "%", MID + NOTCH_W / 2 + 25, cy + 4.5, { size: 11, weight: 600, color: COL.mint });
}
// 弹出提示（布局照 App 的 ToastContent）
function drawToast(c, x, w, t, e) {
  const a = clamp(e.since * 5);
  c.save(); c.globalAlpha *= a;
  text(c, e.host, x + 18, 21, { size: 10.5, weight: 600, color: COL.sec });
  text(c, e.time || "14:26", x + w - 18, 21, { size: 10.5, color: COL.ter, align: "right" });
  const col = e.ok ? COL.mint : COL.coral;
  drawTako(c, x + 34, MENU + 48, 30, e.ok ? "happy" : "sad", Math.floor(t * 4), { shadow: false });
  c.fillStyle = col; c.beginPath(); c.arc(x + 48, MENU + 46, 7, 0, 7); c.fill();
  c.strokeStyle = "#000"; c.lineWidth = 1.5; c.stroke();
  icon(c, e.ok ? "check" : "xmark", x + 48, MENU + 46, 9, "#000", { lw: 3.4 });
  text(c, e.title, x + 66, MENU + 27, { size: 14, weight: 600 });
  text(c, e.sub, x + 66, MENU + 45, { size: 11, color: COL.sec });
  c.fillStyle = alpha(col, 0.55);
  const cw = (w - 80) * (1 - clamp(e.since / 5));
  rr(c, x + 40 + (w - 80 - cw) / 2, MENU + 55, cw, 2, 1); c.fill();
  c.restore();
}
// 二级页面的标题行
function pageHeader(c, x, w, title, sub, o = {}) {
  c.fillStyle = "rgba(255,255,255,0.08)"; c.beginPath(); c.arc(x + 12, 22 + MENU - 18, 12, 0, 7); c.fill();
  icon(c, "back", x + 12, 22 + MENU - 18, 13, COL.sec);
  text(c, title, x + 34, MENU + 4, { size: 13.5, weight: 600 });
  text(c, sub, x + 34, MENU + 19, { size: 10.5, color: COL.ter, max: w - 200 });
  let rx = x + w;
  if (o.refresh !== false) {
    c.fillStyle = "rgba(255,255,255,0.08)"; c.beginPath(); c.arc(rx - 12, MENU + 4, 12, 0, 7); c.fill();
    icon(c, "refresh", rx - 12, MENU + 4, 12, COL.sec); rx -= 32;
  }
  if (o.status) { const pw = measure(c, o.status, { size: 10.5, weight: 700 }) + 18; c.fillStyle = alpha(o.statusCol || COL.mint, 0.18); rr(c, rx - pw, MENU - 7, pw, 22, 11); c.fill(); text(c, o.status, rx - pw / 2, MENU + 8, { size: 10.5, weight: 700, color: o.statusCol || COL.mint, align: "center" }); rx -= pw + 8; }
  if (o.copy) { const pw = measure(c, o.copy, { size: 10.5, weight: 600 }) + 32; c.fillStyle = "rgba(255,255,255,0.07)"; rr(c, rx - pw, MENU - 7, pw, 22, 11); c.fill(); icon(c, "copy", rx - pw + 13, MENU + 4, 10, COL.ter); text(c, o.copy, rx - pw + 22, MENU + 8, { size: 10.5, weight: 600, color: COL.ter }); }
  if (o.right) o.right(rx);
}

// 曲线（详情页里的小图表）：pts = [[x0..1, y]]；log：对数坐标
function chart(c, x, y, w, h, o) {
  c.fillStyle = "rgba(255,255,255,0.05)"; rr(c, x, y, w, h, 12); c.fill();
  let lx = x + 14;
  lx += text(c, o.title, lx, y + 20, { size: 10.5, weight: 600, color: COL.sec }) + 10;
  for (const s of o.series) {
    if (s.legend === false) continue;
    c.fillStyle = s.col; if (s.barLegend) c.fillRect(lx + 2, y + 11, 6, 10); else { rr(c, lx, y + 15, 10, 3, 1.5); c.fill(); }
    lx += 14 + text(c, s.name, lx + 14, y + 20, { size: 10, color: COL.ter }) + 4;
    if (s.val) lx += text(c, s.val, lx, y + 20, { size: 10, weight: 500, color: COL.sec }) + 10;
    else lx += 6;
  }
  if (o.tag) { const tw = measure(c, o.tag, { size: 9.5 }) + 14; c.fillStyle = "rgba(255,255,255,0.07)"; rr(c, x + w - 14 - tw, y + 26, tw, 16, 5); c.fill(); text(c, o.tag, x + w - 21, y + 37.5, { size: 9.5, color: COL.sec, align: "right" }); }
  if (o.corner) text(c, o.corner, x + w - 14, y + 20, { size: 10, color: COL.ter, align: "right" });
  const px0 = x + 56, px1 = x + w - 12, py0 = y + 34, py1 = y + h - 12;
  c.strokeStyle = "rgba(255,255,255,0.06)"; c.lineWidth = 0.8;
  for (const yy of [py0, (py0 + py1) / 2, py1]) { c.beginPath(); c.moveTo(px0, yy); c.lineTo(px1, yy); c.stroke(); }
  const [lo, hi] = o.range;
  const Y = v => { const f = o.log ? (Math.log10(v) - Math.log10(lo)) / (Math.log10(hi) - Math.log10(lo)) : (v - lo) / (hi - lo); return py1 - clamp(f, -0.05, 1.05) * (py1 - py0); };
  text(c, o.labels ? o.labels[0] : String(hi), px0 - 6, py0 + 4, { size: 8.5, font: MONO, color: COL.ter, align: "right" });
  text(c, o.labels ? o.labels[1] : String(lo), px0 - 6, py1 + 3, { size: 8.5, font: MONO, color: COL.ter, align: "right" });
  if (o.target != null) {
    c.setLineDash([3, 3]); c.strokeStyle = alpha(COL.amber, 0.8); c.lineWidth = 1;
    c.beginPath(); c.moveTo(px0, Y(o.target)); c.lineTo(px1 - 50, Y(o.target)); c.stroke(); c.setLineDash([]);
    text(c, o.targetLabel || "", px1, Y(o.target) + 3.5, { size: 8.5, weight: 700, color: COL.amber, align: "right" });
  }
  for (const s of o.series) {
    if (!s.pts.length) continue;
    if (s.bars) {
      c.fillStyle = alpha(s.col, 0.55);
      for (const [fx, v] of s.pts) { const bx = lerp(px0, px1, fx); c.fillRect(bx - 7, Y(v), 14, py1 - Y(v)); }
      continue;
    }
    if (s.dash) c.setLineDash([3, 3]);
    c.strokeStyle = s.col; c.lineWidth = s.lw || 1.8; c.beginPath();
    s.pts.forEach(([fx, v], i) => { const px = lerp(px0, px1, fx), py = Y(v); i ? c.lineTo(px, py) : c.moveTo(px, py); });
    c.stroke(); c.setLineDash([]);
    if (s.dots) { c.fillStyle = s.col; for (const [fx, v] of s.pts) { c.beginPath(); c.arc(lerp(px0, px1, fx), Y(v), 3, 0, 7); c.fill(); } }
  }
}

// ------------------------------------------------------------------ 设置窗口（macOS 深色，系统控件风格）
const SET = { bg: "#2A2A2C", side: "#232325", group: "rgba(255,255,255,0.045)", line: "rgba(255,255,255,0.07)", text: "rgba(255,255,255,0.88)", sec: "rgba(255,255,255,0.5)", ctrl: "rgba(255,255,255,0.13)", sel: "rgba(255,255,255,0.10)", accent: "#3D8BFF" };
function macWindow(c, x, y, w, h, o = {}) {
  c.save();
  c.shadowColor = "rgba(0,0,0,0.45)"; c.shadowBlur = 50; c.shadowOffsetY = 20;
  c.fillStyle = SET.bg; rr(c, x, y, w, h, 12); c.fill();
  c.restore();
  c.save(); rr(c, x, y, w, h, 12); c.clip();
  if (o.side) { c.fillStyle = SET.side; c.fillRect(x, y, o.side, h); c.fillStyle = "rgba(0,0,0,0.35)"; c.fillRect(x + o.side, y, 1, h); }
  ["#FF5F57", "#FEBC2E", "#28C840"].forEach((col, i) => { c.fillStyle = col; c.beginPath(); c.arc(x + 20 + i * 20, y + 20, 6, 0, 7); c.fill(); });
  if (o.title) text(c, o.title, x + w / 2, y + 25, { size: 13, weight: 600, color: SET.sec, align: "center" });
  if (o.content) o.content();
  c.restore();
  c.strokeStyle = "rgba(255,255,255,0.12)"; c.lineWidth = 1; rr(c, x, y, w, h, 12); c.stroke();
}
// 侧栏的一项：彩色圆角方块图标 + 标题 + 副标题
function sideItem(c, x, y, w, it, sel) {
  if (sel) { c.fillStyle = sel === true ? "rgba(255,255,255,0.10)" : sel; rr(c, x + 8, y, w - 16, 40, 8); c.fill(); }
  const g = c.createLinearGradient(0, y + 6, 0, y + 34); g.addColorStop(0, it.col); g.addColorStop(1, shade(it.col, -30));
  c.fillStyle = g; rr(c, x + 16, y + 6, 28, 28, 7); c.fill();
  icon(c, it.icon, x + 30, y + 20, 15, "#fff", { inner: it.col });
  if (it.dot) { c.fillStyle = it.dot; c.beginPath(); c.arc(x + 42, y + 32, 4.2, 0, 7); c.fill(); c.strokeStyle = SET.side; c.lineWidth = 1.5; c.stroke(); }
  text(c, it.title, x + 54, y + 18, { size: 13, weight: 500, color: SET.text });
  text(c, it.sub, x + 54, y + 34, { size: 10.5, color: SET.sec });
}
// 分组：rows = [{label, help, value, kind, ...}]，返回高度
const ROW_H = 36;
function formGroup(c, x, y, w, rows, t, o = {}) {
  const h = rows.reduce((a, r) => a + (r.h || ROW_H), 0);
  if (!o.bare) {
    c.fillStyle = SET.group; rr(c, x, y, w, h, 9); c.fill();
    c.strokeStyle = "rgba(255,255,255,0.06)"; c.lineWidth = 0.8; rr(c, x, y, w, h, 9); c.stroke();
  }
  let ry = y;
  rows.forEach((r, i) => {
    const rh = r.h || ROW_H, cy = ry + rh / 2;
    if (i > 0) { c.fillStyle = SET.line; c.fillRect(x + 12, ry, w - 24, 1); }
    if (r.hl) { c.fillStyle = `rgba(91,232,179,${0.12 * r.hl})`; rr(c, x + 3, ry + 3, w - 6, rh - 6, 7); c.fill(); }
    if (r.custom) { r.custom(x, ry, w, rh); ry += rh; return; }
    const lw = text(c, r.label, x + 12, cy + 4.5, { size: 13, color: SET.text });
    if (r.help) { c.strokeStyle = SET.sec; c.lineWidth = 1; c.beginPath(); c.arc(x + 12 + lw + 11, cy, 6, 0, 7); c.stroke(); text(c, "?", x + 12 + lw + 11, cy + 3.5, { size: 8.5, weight: 600, color: SET.sec, align: "center" }); }
    const vx = x + w - 12;
    if (r.kind === "field") {
      const s = r.value || "";
      if (s) text(c, s, vx, cy + 4.5, { size: 13, color: SET.text, font: r.mono ? MONO : FONT, align: "right" });
      else text(c, r.ph || "", vx, cy + 4.5, { size: 13, color: "rgba(255,255,255,0.28)", font: r.mono ? MONO : FONT, align: "right" });
      if (r.caret) { const cw = s ? 0 : measure(c, r.ph || "", { size: 13, font: r.mono ? MONO : FONT }); if (Math.floor(t * 2.4) % 2 === 0) { c.fillStyle = SET.accent; c.fillRect(vx + 2 - cw * 0, cy - 8, 1.6, 16); } }
    } else if (r.kind === "button") {
      button(c, vx, cy, r.value, { align: "right", press: r.press, primary: r.primary });
    } else if (r.kind === "segment") {
      segment(c, vx, cy, r.options, r.sel, { align: "right", width: r.width });
    } else if (r.kind === "popup") {
      popup(c, vx, cy, r.value, { align: "right", open: r.open });
    } else if (r.kind === "toggle") {
      toggle(c, vx, cy, r.value);
    } else if (r.kind === "text") {
      text(c, r.value, vx, cy + 4.5, { size: 13, color: r.color || SET.sec, align: "right", font: r.mono ? MONO : FONT });
    }
    if (r.extra) r.extra(x, ry, w, rh);
    ry += rh;
  });
  return h;
}
function button(c, x, cy, label, o = {}) {
  const w = measure(c, label, { size: 12.5, weight: 500 }) + 22;
  const bx = o.align === "right" ? x - w : o.align === "center" ? x - w / 2 : x;
  c.fillStyle = o.primary ? SET.accent : o.press ? "rgba(255,255,255,0.28)" : "rgba(255,255,255,0.15)";
  rr(c, bx, cy - 11, w, 22, 6); c.fill();
  c.strokeStyle = "rgba(255,255,255,0.08)"; c.lineWidth = 0.6; rr(c, bx, cy - 11, w, 22, 6); c.stroke();
  text(c, label, bx + w / 2, cy + 4.3, { size: 12.5, weight: 500, color: o.dim ? SET.sec : "#fff", align: "center" });
  return { x: bx, w, cx: bx + w / 2 };
}
function segment(c, x, cy, opts, sel, o = {}) {
  const ws = opts.map(s => measure(c, s, { size: 12.5, weight: 500 }) + 26);
  const total = o.width || ws.reduce((a, b) => a + b, 0);
  const scale = total / ws.reduce((a, b) => a + b, 0);
  const bx = o.align === "right" ? x - total : x;
  c.fillStyle = "rgba(255,255,255,0.08)"; rr(c, bx, cy - 12, total, 24, 7); c.fill();
  let px = bx;
  const pos = [];
  ws.forEach((w0) => { pos.push([px, w0 * scale]); px += w0 * scale; });
  // 选中块可以在两项之间滑动（sel 可以是小数）
  const i0 = Math.floor(sel), i1 = Math.min(opts.length - 1, i0 + 1), f = sel - i0;
  const sx = lerp(pos[i0][0], pos[i1][0], f), sw = lerp(pos[i0][1], pos[i1][1], f);
  c.fillStyle = "rgba(255,255,255,0.22)"; rr(c, sx + 2, cy - 10, sw - 4, 20, 5.5); c.fill();
  opts.forEach((s, i) => text(c, s, pos[i][0] + pos[i][1] / 2, cy + 4.3, { size: 12.5, weight: 500, color: "#fff", align: "center" }));
  return pos.map(([p, w]) => [p + w / 2, cy]);
}
function popup(c, x, cy, label, o = {}) {
  const w = measure(c, label, { size: 13, weight: 500 }) + 26;
  const bx = o.align === "right" ? x - w : x;
  text(c, label, bx, cy + 4.5, { size: 13, weight: 500, color: SET.text });
  c.fillStyle = "rgba(255,255,255,0.14)"; rr(c, bx + w - 16, cy - 9, 16, 18, 4); c.fill();
  c.strokeStyle = "#fff"; c.lineWidth = 1.3; c.lineCap = "round";
  c.beginPath(); c.moveTo(bx + w - 11.5, cy - 2); c.lineTo(bx + w - 8, cy - 5.5); c.lineTo(bx + w - 4.5, cy - 2); c.stroke();
  c.beginPath(); c.moveTo(bx + w - 11.5, cy + 2); c.lineTo(bx + w - 8, cy + 5.5); c.lineTo(bx + w - 4.5, cy + 2); c.stroke();
  return { x: bx, w };
}
function toggle(c, x, cy, on) {
  c.fillStyle = on ? "#34C759" : "rgba(255,255,255,0.18)"; rr(c, x - 32, cy - 10, 32, 20, 10); c.fill();
  c.fillStyle = "#fff"; c.beginPath(); c.arc(on ? x - 10 : x - 22, cy, 8.2, 0, 7); c.fill();
}
// 下拉菜单 / 右键菜单：items = [label 或 "-"]，hi = 高亮项（可为小数做过渡），check = 打勾项
function menu(c, x, y, items, o = {}) {
  const w = o.w || Math.max(...items.map(s => s === "-" ? 0 : measure(c, s, { size: 13 }))) + 48;
  const h = items.reduce((a, s) => a + (s === "-" ? 9 : 24), 0) + 10;
  const k = o.k ?? 1;
  c.save();
  c.globalAlpha *= clamp(k * 1.5);
  c.translate(x, y); c.scale(1, lerp(0.92, 1, easeOutCubic(k)));
  c.shadowColor = "rgba(0,0,0,0.45)"; c.shadowBlur = 24; c.shadowOffsetY = 8;
  c.fillStyle = "rgba(48,48,52,0.98)"; rr(c, 0, 0, w, h, 8); c.fill(); c.shadowBlur = 0; c.shadowOffsetY = 0;
  c.strokeStyle = "rgba(255,255,255,0.14)"; c.lineWidth = 0.8; rr(c, 0, 0, w, h, 8); c.stroke();
  let yy = 5;
  const pos = [];
  items.forEach((s, i) => {
    if (s === "-") { c.fillStyle = "rgba(255,255,255,0.12)"; c.fillRect(10, yy + 4, w - 20, 1); yy += 9; pos.push(null); return; }
    if (o.hi === i) { c.fillStyle = SET.accent; rr(c, 5, yy, w - 10, 24, 5); c.fill(); }
    const dis = o.disabled && o.disabled.includes(i);
    if (o.check === i) text(c, "✓", 13, yy + 17, { size: 12, weight: 700, color: "#fff" });
    text(c, s, 30, yy + 17, { size: 13, color: dis ? "rgba(255,255,255,0.3)" : "#fff" });
    pos.push([x + w / 2, y + yy + 12]);
    yy += 24;
  });
  c.restore();
  return pos;
}

// ------------------------------------------------------------------ 光标、高亮、粒子
function drawCursor(c, x, y, s = 1, press = 0) {
  c.save(); c.translate(x, y); c.scale(s * (1 - press * 0.12), s * (1 - press * 0.12));
  c.beginPath(); c.moveTo(0, 0); c.lineTo(0, 22); c.lineTo(5.5, 16.5); c.lineTo(9.5, 25); c.lineTo(13, 23.5); c.lineTo(9, 15.5); c.lineTo(16, 15.5); c.closePath();
  c.fillStyle = "#000"; c.strokeStyle = "#fff"; c.lineWidth = 1.6; c.lineJoin = "round";
  c.shadowColor = "rgba(0,0,0,0.4)"; c.shadowBlur = 6; c.shadowOffsetY = 2;
  c.stroke(); c.fill(); c.restore();
}
// 点击时的涟漪
function ripple(c, t, t0, x, y, col = "255,255,255") {
  const k = (t - t0) / 0.45;
  if (k < 0 || k > 1) return;
  c.save(); c.strokeStyle = `rgba(${col},${0.7 * (1 - k)})`; c.lineWidth = 2 * (1 - k) + 0.5;
  c.beginPath(); c.arc(x, y, 4 + 16 * easeOutCubic(k), 0, 7); c.stroke(); c.restore();
}
// 薄荷色高亮框 + 可选标签
function highlight(c, x, y, w, h, k, label, o = {}) {
  if (k <= 0) return;
  c.save();
  c.globalAlpha *= clamp(k);
  const g = 1 + (1 - easeOutCubic(clamp(k))) * 0.06;
  c.translate(x + w / 2, y + h / 2); c.scale(g, g); c.translate(-(x + w / 2), -(y + h / 2));
  c.shadowColor = alpha(o.col || COL.mint, 0.7); c.shadowBlur = 12;
  c.strokeStyle = o.col || COL.mint; c.lineWidth = o.lw || 2; rr(c, x, y, w, h, o.r ?? 10); c.stroke();
  c.shadowBlur = 0;
  if (label) {
    const fs = o.size || 12;
    const lw = measure(c, label, { size: fs, weight: 700 }) + 16;
    let lx = o.labelX ?? (x + w / 2 - lw / 2), ly = o.below ? y + h + 6 : y - fs - 14;
    // side: "left"：标签放在左边（右端对齐到 o.edge，默认是框的左边），竖直居中
    if (o.side === "left") { lx = (o.edge ?? x) - 12 - lw; ly = y + h / 2 - (fs + 9) / 2; }
    c.fillStyle = o.col || COL.mint; rr(c, lx, ly, lw, fs + 9, (fs + 9) / 2); c.fill();
    text(c, label, lx + lw / 2, ly + fs + 1.5, { size: fs, weight: 700, color: "#06121A", align: "center" });
  }
  c.restore();
}
function burst(c, t, t0, x, y, o = {}) {
  const k = (t - t0) / (o.dur || 0.8);
  if (k < 0 || k > 1) return;
  const n = o.n || 26, cols = o.cols || [COL.mint, COL.cyan, "#fff", COL.amber];
  c.save();
  const a0 = c.globalAlpha;
  for (let i = 0; i < n; i++) {
    const ang = rnd(i + (o.seed || 0)) * Math.PI * 2, sp = (o.speed || 260) * (0.4 + rnd(i * 5 + 1) * 0.8);
    const e = easeOutCubic(k);
    const px = x + Math.cos(ang) * sp * e, py = y + Math.sin(ang) * sp * e + (o.grav ?? 120) * k * k;
    const sz = (o.size || 8) * (1 - k * 0.6);
    c.globalAlpha = a0 * (1 - k) * (o.alpha ?? 1);
    c.fillStyle = cols[i % cols.length];
    c.fillRect(px - sz / 2, py - sz / 2, sz, sz);
  }
  c.restore();
}
function flash(c, t, t0, dur = 0.3, col = "255,255,255", max = 0.85) {
  const k = (t - t0) / dur;
  if (k < 0 || k > 1) return;
  c.fillStyle = `rgba(${col},${max * Math.pow(1 - k, 2.2)})`; c.fillRect(0, 0, W, H);
}
// 光标路径：pts = [[秒, x, y], ...]，相邻点之间 easeInOutCubic；clicks = [秒, ...]
function cursorAt(t, pts) {
  if (t <= pts[0][0]) return [pts[0][1], pts[0][2]];
  for (let i = 1; i < pts.length; i++) if (t <= pts[i][0]) {
    const k = easeInOutCubic((t - pts[i - 1][0]) / Math.max(1e-6, pts[i][0] - pts[i - 1][0]));
    return [lerp(pts[i - 1][1], pts[i][1], k), lerp(pts[i - 1][2], pts[i][2], k)];
  }
  const p = pts[pts.length - 1]; return [p[1], p[2]];
}
function pressAt(t, clicks) { let p = 0; for (const ct of clicks) p = Math.max(p, 1 - Math.abs(t - ct) * 9); return Math.max(0, p); }
