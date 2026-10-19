// ServerIsland 官网：语言切换、首屏动画、刘海演示、滚动出现。纯前端，没有任何外部依赖。
(function () {
  const cfg = window.SI_CONFIG || {};
  const $ = (s, el = document) => el.querySelector(s);
  const $$ = (s, el = document) => Array.from(el.querySelectorAll(s));
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ------------------------------------------------------------ 语言
  const TITLES = {
    zh: "ServerIsland — 把服务器装进刘海里",
    en: "ServerIsland — Your servers, in the notch",
  };
  function storedLang() {
    try { return localStorage.getItem("si-lang"); } catch (e) { return null; }
  }
  function setLang(lang, save) {
    document.documentElement.dataset.lang = lang;
    document.documentElement.lang = lang === "zh" ? "zh-CN" : "en";
    // 子页面（手册、功能介绍）在 <body data-title-zh / data-title-en> 里写自己的标题
    document.title = document.body.dataset[lang === "zh" ? "titleZh" : "titleEn"] || TITLES[lang];
    $$("img[data-shot]").forEach(img => { img.src = `assets/shots/${lang}/${img.dataset.shot}.png`; });
    // 宣传视频：中文页面放中文版，英文页面放英文版
    $$("video.js-promo").forEach(v => {
      const src = lang === "zh" ? "assets/promo.mp4" : "assets/promo-en.mp4";
      if (!v.getAttribute("src") || !v.getAttribute("src").endsWith(src.split("/")[1])) {
        v.pause(); v.src = src; v.poster = lang === "zh" ? "assets/promo-poster.jpg" : "assets/promo-poster-en.jpg";
      }
    });
    if (save) { try { localStorage.setItem("si-lang", lang); } catch (e) { /* 隐私模式下忽略 */ } }
    island.refreshText();
  }
  // 和 index.html 开头的小脚本一致：手动选过的优先，否则跟随系统语言
  const lang0 = document.documentElement.dataset.lang === "zh" ? "zh" : "en";
  const isZh = () => document.documentElement.dataset.lang === "zh";
  $(".lang-toggle").addEventListener("click", () => setLang(isZh() ? "en" : "zh", true));

  // ------------------------------------------------------------ 手册目录：滚动时高亮当前小节
  (function toc() {
    const links = $$(".toc a[href^='#']");
    if (!links.length || !("IntersectionObserver" in window)) return;
    const map = new Map(links.map(a => [a.getAttribute("href").slice(1), a]));
    const io = new IntersectionObserver(es => es.forEach(e => {
      if (!e.isIntersecting) return;
      links.forEach(a => a.classList.remove("active"));
      map.get(e.target.id)?.classList.add("active");
    }), { rootMargin: "-80px 0px -70% 0px" });
    map.forEach((_, id) => { const el = document.getElementById(id); if (el) io.observe(el); });
  })();

  // ------------------------------------------------------------ 版本、GitHub 和下载
  $$(".js-version").forEach(el => { el.textContent = cfg.version || "0.3.0"; });
  const repo = (cfg.repo || "").replace(/\/$/, "");
  if (repo) {
    $$(".js-github").forEach(a => { a.href = repo + (a.dataset.path || ""); a.target = "_blank"; a.rel = "noopener"; });
    $$(".js-repo-url").forEach(el => { el.textContent = repo; });
  }
  if (repo) {
    const m = repo.match(/github\.com\/([^/]+\/[^/]+)/);
    if (m && window.fetch) {
      fetch("https://api.github.com/repos/" + m[1]).then(r => r.ok ? r.json() : null).then(d => {
        if (!d || typeof d.stargazers_count !== "number") return;
        const n = d.stargazers_count, txt = n >= 1000 ? (n / 1000).toFixed(1).replace(/\.0$/, "") + "k" : String(n);
        $$(".js-stars").forEach(el => { el.textContent = txt; });
        $$(".js-star-count").forEach(el => { el.hidden = false; });
      }).catch(() => {});
    }
  }
  const dl = cfg.downloadURL || (repo ? repo + "/releases/latest" : "");
  $$(".js-download-real").forEach(a => {
    if (dl) { a.href = dl; return; }
    a.addEventListener("click", e => {
      e.preventDefault();
      const zh = a.querySelector('[lang="zh"]'), en = a.querySelector('[lang="en"]');
      zh.textContent = "即将开放，敬请期待"; en.textContent = "Coming soon";
    });
  });

  // ------------------------------------------------------------ 下载：按系统推荐，▾ 选择其他平台
  // 图标从下载区的卡片里拷贝（data-os），文件地址从 GitHub 最新 Release 的附件里找，找不到就打开 Release 页面。
  // 调试：?os=windows / linux / mac / mobile
  const PLATFORMS = {
    mac: { name: "macOS", suffix: ".dmg",
           zh: "macOS 14+ · Apple 芯片与 Intel · DMG", en: "macOS 14+ · Apple silicon & Intel · DMG",
           reqZh: "macOS 14 及以上", reqEn: "macOS 14+" },
    win: { name: "Windows", suffix: "-win-x64.zip",
           zh: "Windows 10 / 11 · 64 位 · 解压即用", en: "Windows 10 / 11 · 64-bit · unzip and run",
           reqZh: "Windows 10 / 11", reqEn: "Windows 10 / 11" },
    linux: { name: "Linux", suffix: "-linux-x64.tar.gz",
             zh: "x64 · X11 / XWayland · tar.gz", en: "x64 · X11 / XWayland · tar.gz",
             reqZh: "Linux x64", reqEn: "Linux x64" },
  };
  function detectOS() {
    const q = (new URLSearchParams(location.search).get("os") || "").toLowerCase();
    if (q) return q.startsWith("win") ? { os: "win" } : q.startsWith("lin") ? { os: "linux" } : q === "mobile" ? { os: "mac", mobile: true } : { os: "mac" };
    const ua = navigator.userAgent || "";
    const plat = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "";
    // iPad 会冒充 Mac：用触摸点数区分
    if (/android|iphone|ipad|ipod|mobile/i.test(ua) || (/mac/i.test(plat) && navigator.maxTouchPoints > 1)) return { os: "mac", mobile: true };
    if (/win/i.test(plat) || /windows/i.test(ua)) return { os: "win" };
    if (/linux|x11|cros/i.test(plat + " " + ua)) return { os: "linux" };
    return { os: "mac" };
  }
  const detected = detectOS();
  const releasePage = repo ? repo + "/releases/latest" : "#download";
  const dlLinks = { mac: releasePage, win: releasePage, linux: releasePage };
  const iconOf = os => { const svg = $(`.dl-card[data-os="${os}"] b svg`); return svg ? svg.cloneNode(true) : document.createElement("span"); };
  const T = (zh, en) => `<span lang="zh">${zh}</span><span lang="en">${en}</span>`;

  const main = $("[data-dl-main]"), toggle = $("[data-dl-toggle]"), menu = $("[data-dl-menu]");
  function renderDownloads() {
    const p = PLATFORMS[detected.os];
    if (main) {
      main.href = dlLinks[detected.os];
      const icon = $("[data-dl-icon]", main);
      if (icon) { icon.innerHTML = ""; const svg = iconOf(detected.os); svg.setAttribute("width", "18"); svg.setAttribute("height", "18"); icon.appendChild(svg); }
      $("[data-dl-label-zh]", main).textContent = "下载 " + p.name + " 版";
      $("[data-dl-label-en]", main).textContent = "Download for " + p.name;
    }
    $$("[data-dl-req-zh]").forEach(el => { el.textContent = p.reqZh; });
    $$("[data-dl-req-en]").forEach(el => { el.textContent = p.reqEn; });
    // 按钮下面的"其他平台"
    const others = $("[data-dl-others]");
    if (others) {
      const links = Object.keys(PLATFORMS).filter(k => k !== detected.os)
        .map(k => `<a class="dl-chip" href="${dlLinks[k]}" data-os-link="${k}"></a>`).join("");
      others.innerHTML = T("其他平台：", "Other platforms: ") + links + `<a class="dl-chip ghost" href="#download">${T("全部下载", "All downloads")}</a>`;
      $$("[data-os-link]", others).forEach(a => { const k = a.dataset.osLink; a.appendChild(iconOf(k)); a.appendChild(document.createTextNode(PLATFORMS[k].name)); });
    }
    // ▾ 菜单
    if (menu) {
      menu.innerHTML = "";
      Object.keys(PLATFORMS).forEach(k => {
        const q = PLATFORMS[k];
        const a = document.createElement("a");
        const rec = k === detected.os && !detected.mobile;
        a.setAttribute("role", "menuitem"); a.href = dlLinks[k]; a.className = "dl-item" + (rec ? " current" : "");
        a.appendChild(iconOf(k));
        const text = document.createElement("span");
        text.innerHTML = `<b>${q.name}${rec ? ` <em class="dl-rec">${T("推荐", "For you")}</em>` : ""}</b><small>${T(q.zh, q.en)}</small>`;
        a.appendChild(text);
        menu.appendChild(a);
      });
      const all = document.createElement("a");
      all.className = "dl-item dl-all"; all.setAttribute("role", "menuitem");
      all.href = repo ? repo + "/releases" : "#download"; all.target = "_blank"; all.rel = "noopener";
      all.innerHTML = T("所有版本和更新说明 →", "All releases and notes →");
      menu.appendChild(all);
    }
    // 下载区的三张卡片：直接指向各自的安装包
    $$(".dl-card[data-os]").forEach(card => { card.href = dlLinks[card.dataset.os]; card.removeAttribute("target"); });
    const mobileNote = $("[data-dl-mobile]");
    if (mobileNote) mobileNote.hidden = !detected.mobile;
  }
  renderDownloads();

  function setMenu(open) {
    if (!menu || !toggle) return;
    menu.hidden = !open;
    toggle.setAttribute("aria-expanded", String(open));
  }
  if (toggle) {
    toggle.addEventListener("click", e => { e.stopPropagation(); setMenu(menu.hidden); });
    document.addEventListener("click", e => { if (!menu.hidden && !menu.contains(e.target)) setMenu(false); });
    document.addEventListener("keydown", e => { if (e.key === "Escape") setMenu(false); });
  }

  // 从最新的 Release 找到各平台安装包的直接下载地址
  const repoPath = repo && (repo.match(/github\.com\/([^/]+\/[^/]+)/) || [])[1];
  if (repoPath && window.fetch) {
    fetch("https://api.github.com/repos/" + repoPath + "/releases/latest").then(r => r.ok ? r.json() : null).then(rel => {
      if (!rel || !Array.isArray(rel.assets)) return;
      Object.keys(PLATFORMS).forEach(k => {
        const asset = rel.assets.find(a => (a.name || "").toLowerCase().endsWith(PLATFORMS[k].suffix));
        if (asset) dlLinks[k] = asset.browser_download_url;
      });
      if (rel.tag_name) $$(".js-version").forEach(el => { el.textContent = rel.tag_name.replace(/^v/i, ""); });
      renderDownloads();
    }).catch(() => {});
  }

  // ------------------------------------------------------------ 导航阴影
  const nav = $(".nav");
  const onScroll = () => nav.classList.toggle("scrolled", window.scrollY > 10);
  window.addEventListener("scroll", onScroll, { passive: true }); onScroll();

  // ------------------------------------------------------------ 滚动出现
  if ("IntersectionObserver" in window && !reduce) {
    const io = new IntersectionObserver(es => es.forEach(e => {
      if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
    }), { threshold: 0.12, rootMargin: "0px 0px -40px 0px" });
    $$(".reveal").forEach(el => io.observe(el));
  } else {
    $$(".reveal").forEach(el => el.classList.add("in"));
  }

  // ------------------------------------------------------------ 所有 Tako 一起动
  let tick = 0;
  const takos = () => $$("canvas.tako");
  function drawTakos() { takos().forEach(cv => Tako.draw(cv, cv.dataset.mood || "idle", tick)); }
  drawTakos();
  if (!reduce) setInterval(() => { tick++; drawTakos(); }, 340);

  // ------------------------------------------------------------ 像素字 ServerIsland（和视频里一样从散落到成形）
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
  const rnd = i => { const s = Math.sin(i * 12.9898) * 43758.5453; return s - Math.floor(s); };
  const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
  const easeOutBack = (k, s = 1.4) => 1 + (s + 1) * Math.pow(k - 1, 3) + s * Math.pow(k - 1, 2);
  (function pixelWord() {
    const cv = $(".pixel-word"); if (!cv) return;
    const W = 560, H = 96, dpr = Math.min(window.devicePixelRatio || 1, 3);
    cv.width = W * dpr; cv.height = H * dpr;
    const c = cv.getContext("2d"); c.setTransform(dpr, 0, 0, dpr, 0, 0);
    const word = wordCells("ServerIsland"), cell = Math.floor((W - 20) / word.cols);
    const x0 = (W - word.cols * cell) / 2, cy = H / 2;
    const t0 = performance.now();
    function frame(now) {
      const k = reduce ? 1 : clamp((now - t0 - 150) / 1500);
      c.clearRect(0, 0, W, H);
      const grad = c.createLinearGradient(x0, 0, x0 + word.cols * cell, 0);
      grad.addColorStop(0, "#5BE6B5"); grad.addColorStop(1, "#7CCBFF");
      c.fillStyle = grad;
      c.shadowColor = "rgba(91,230,181,0.45)"; c.shadowBlur = cell * 1.4;
      word.cells.forEach(([col, row], i) => {
        const kk = clamp((k - rnd(i * 3 + 1) * 0.45) / 0.55);
        if (kk <= 0) return;
        const e = easeOutBack(kk);
        const tx = x0 + col * cell, ty = cy + (row - 3.5) * cell;
        const sx = W / 2 + (rnd(i * 7 + 1) - 0.5) * W * 1.3, sy = cy + (rnd(i * 11 + 1) - 0.5) * H * 3;
        c.globalAlpha = clamp(kk * 3);
        c.fillRect(sx + (tx - sx) * e, sy + (ty - sy) * e, cell - 0.6, cell - 0.6);
      });
      c.globalAlpha = 1;
      if (k < 1) requestAnimationFrame(frame);
    }
    requestAnimationFrame(frame);
  })();

  // ------------------------------------------------------------ 首屏夜空：闪烁的像素星星
  (function sky() {
    const cv = $(".hero-sky"); if (!cv) return;
    const c = cv.getContext("2d");
    let W = 0, H = 0, stars = [];
    function resize() {
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      W = cv.clientWidth; H = cv.clientHeight;
      cv.width = W * dpr; cv.height = H * dpr; c.setTransform(dpr, 0, 0, dpr, 0, 0);
      const n = Math.round(W * H / 9000);
      stars = Array.from({ length: n }, (_, i) => ({
        x: rnd(i * 5 + 2) * W, y: rnd(i * 9 + 3) * H * 0.85, s: rnd(i * 13) < 0.85 ? 2 : 3,
        p: rnd(i * 17) * 6.28, v: 0.6 + rnd(i * 19) * 1.6, col: rnd(i * 23) < 0.2 ? "#7CCBFF" : (rnd(i * 29) < 0.15 ? "#5BE6B5" : "#ffffff"),
      }));
    }
    function frame(now) {
      const t = now / 1000;
      const g = c.createLinearGradient(0, 0, 0, H);
      g.addColorStop(0, "#05070d"); g.addColorStop(0.55, "#0a1022"); g.addColorStop(1, "#111a33");
      c.fillStyle = g; c.fillRect(0, 0, W, H);
      // 底部一层淡淡的光晕，接住 Mac
      const r = c.createRadialGradient(W / 2, H * 1.05, 10, W / 2, H * 1.05, W * 0.6);
      r.addColorStop(0, "rgba(91,230,181,0.16)"); r.addColorStop(1, "rgba(91,230,181,0)");
      c.fillStyle = r; c.fillRect(0, 0, W, H);
      for (const s of stars) {
        c.globalAlpha = 0.25 + 0.6 * (0.5 + 0.5 * Math.sin(t * s.v + s.p));
        c.fillStyle = s.col; c.fillRect(Math.round(s.x), Math.round(s.y), s.s, s.s);
      }
      c.globalAlpha = 1;
      if (!reduce) requestAnimationFrame(frame);
    }
    resize(); window.addEventListener("resize", resize);
    requestAnimationFrame(frame);
  })();

  // ------------------------------------------------------------ 刘海演示
  const island = (function () {
    const el = $(".island"), mac = $(".mac");
    if (!el) return { refreshText() {} };
    const toastTako = $(".toast canvas.tako", el);
    const TOASTS = [
      { mood: "happy", zh: ["NEP 训练完成", "4090 工作站 · 20,000 代 · nep-train"], en: ["NEP training finished", "4090 Workstation · 20,000 gen · nep-train"] },
      { mood: "sad", zh: ["aimd_LGPS_1200K 超时", "HPC 集群 · Timeout · 用时 48:00:00"], en: ["aimd_LGPS_1200K timed out", "HPC Cluster · Timeout · took 48:00:00"] },
      { mood: "happy", zh: ["relax_LiCoO2_hse 已完成", "HPC 集群 · 用时 11:42:05 · 31 离子步"], en: ["relax_LiCoO2_hse finished", "HPC Cluster · took 11:42:05 · 31 ionic steps"] },
    ];
    let toastIdx = 0, hovering = false, timer = null;

    function showToast() {
      const t = TOASTS[toastIdx % TOASTS.length];
      toastTako.dataset.mood = t.mood;
      refreshText();
      set("toast");
    }
    function refreshText() {
      const t = TOASTS[toastIdx % TOASTS.length], s = isZh() ? t.zh : t.en;
      $(".js-toast-title", el).textContent = s[0];
      $(".js-toast-sub", el).textContent = s[1];
      updateJobs(0);
    }
    function set(state) { el.dataset.state = state; }

    // 自动演示：收起 → 提示 → 收起 → 展开 → 收起 …；鼠标悬停时一直展开
    const SCRIPT = [["collapsed", 2600], ["toast", 3200], ["collapsed", 1800], ["panel", 5200]];
    let step = 0;
    function next() {
      if (hovering) return;
      const [state, dur] = SCRIPT[step % SCRIPT.length];
      if (state === "toast") showToast(); else set(state);
      if (state === "toast") toastIdx++;
      step++;
      timer = setTimeout(next, dur);
    }
    el.addEventListener("mouseenter", () => { hovering = true; clearTimeout(timer); mac.classList.add("touched"); set("panel"); });
    el.addEventListener("mouseleave", () => { hovering = false; set("collapsed"); timer = setTimeout(next, 1600); });
    el.addEventListener("click", () => { mac.classList.add("touched"); set(el.dataset.state === "panel" ? "collapsed" : "panel"); });

    // 进度条慢慢往前走
    const jobs = $$(".job[data-k]", el);
    function fmt(n) {
      if (n >= 1e6) return (n / 1e6).toFixed(2) + "M";
      return Math.round(n).toLocaleString("en-US");
    }
    function updateJobs(dt) {
      jobs.forEach(j => {
        let k = parseFloat(j.dataset.k) + parseFloat(j.dataset.speed) * dt;
        if (k > 0.97) k = parseFloat(j.dataset.k0 || j.dataset.k);
        j.dataset.k0 = j.dataset.k0 || j.dataset.k;
        j.dataset.k = k.toFixed(5);
        $(".bar > i", j).style.width = (k * 100).toFixed(1) + "%";
        const pct = $(".js-pct", j); if (pct) pct.textContent = Math.round(k * 100) + "%";
        const st = $(".js-steps", j);
        if (st) {
          const total = +st.dataset.total, unit = total === 20000 ? (isZh() ? " 代" : " gen") : (isZh() ? " 步" : " steps");
          st.textContent = `${fmt(k * total)}/${fmt(total)}${unit}`;
        }
      });
      const nep = jobs[1];
      if (nep) {
        const k = parseFloat(nep.dataset.k);
        $(".js-ring", el).style.strokeDashoffset = (47.1 * (1 - k)).toFixed(2);
        $(".js-ring-text", el).textContent = Math.round(k * 100) + "%";
      }
    }
    updateJobs(0);
    if (!reduce) {
      setInterval(() => updateJobs(1), 1000);
      timer = setTimeout(next, 1400);
    }
    return { refreshText };
  })();

  setLang(lang0, false);
})();
