// 小章鱼 Tako：和 App 里的 Pet.swift、宣传视频 promo/index.html 是同一张 16×14 像素网格。
(function () {
  const HEAD = ["......BBBB......", "....BBBBBBBB....", "...BHHBBBBBBB...", "..BHHBBBBBBBBB..", "..BHBBBBBBBBBB..",
    ".BBBBBBBBBBBBBB.", ".BBBBBBBBBBBBBB.", ".BBBBBBBBBBBBBB.", ".BBBBBBBBBBBBBB.", "..SBBBBBBBBBBS.."];
  const LEGS_A = [".SBB.BB..BB.BBS.", ".BB..BB..BB..BB.", "BB..BB....BB..BB", "B...B......B...B"];
  const LEGS_B = [".SBB.BB..BB.BBS.", "..BB.BB..BB.BB..", "..B..BB..BB..B..", ".BB...B..B...BB."];
  const LEGS_T = [".SBBBBB..BBBBBS.", "..BB.BB..BB.BB..", "...B.B....B.B...", "................"];
  const COL = { B: "#5CE6B5", S: "#2EAD87", H: "#BDF9DF", E: "#0A0F1F", W: "#FFFFFF", C: "#FF8FAB", M: "#0A0F1F", R: "#7CC8FF" };
  const SAD = { B: "#FF8C8C", S: "#CC545C", H: "#FFCCCC" };

  function grid(mood, tick) {
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

  /** 在 canvas 上画一只 Tako。size 是 CSS 像素边长；bob 是上下浮动的像素数。 */
  function draw(canvas, mood, tick, bob) {
    const size = +canvas.dataset.size || canvas.width;
    const dpr = Math.min(window.devicePixelRatio || 1, 3);
    if (canvas.width !== size * dpr) {
      canvas.width = size * dpr; canvas.height = size * dpr;
      canvas.style.width = size + "px"; canvas.style.height = size + "px";
    }
    const c = canvas.getContext("2d");
    c.setTransform(dpr, 0, 0, dpr, 0, 0);
    c.clearRect(0, 0, size, size);
    const px = size / 16, g = grid(mood, tick);
    const pal = mood === "sad" ? Object.assign({}, COL, SAD) : COL;
    const oy = (size - 14 * px) / 2 + (bob || 0);
    for (let r = 0; r < 14; r++) for (let col = 0; col < 16; col++) {
      const ch = g[r][col];
      if (ch === ".") continue;
      c.fillStyle = pal[ch];
      c.fillRect(col * px, oy + r * px, px + 0.35, px + 0.35);
    }
  }

  window.Tako = { grid, draw, COL };
})();
