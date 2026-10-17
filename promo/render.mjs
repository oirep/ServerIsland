// 逐帧渲染发布视频：无头 Chrome 调用 renderFrame(t) → 截图 → 管道送进 FFmpeg。
// 画面是时间的纯函数，所以与渲染速度无关，帧间隔严格均匀，不会掉帧。
//
//   node promo/render.mjs                   # 完整视频 → promo/out/ServerIsland-v0.1.mp4
//   node promo/render.mjs --stills 2,5,12   # 只导出这些时刻（秒）的静帧，便于检查
//   node promo/render.mjs --from 20 --to 26 # 只渲染一段（调试用）
import { spawn } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import puppeteer from "puppeteer-core";

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = join(HERE, "out");
mkdirSync(OUT, { recursive: true });

const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const stills = opt("--stills");
const FPS = Number(opt("--fps", 60));

const browser = await puppeteer.launch({
  executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  headless: true,
  args: ["--allow-file-access-from-files", "--force-device-scale-factor=1", "--hide-scrollbars", "--force-color-profile=srgb"],
  defaultViewport: { width: 1920, height: 1080, deviceScaleFactor: 1 },
});
const page = await browser.newPage();
page.on("pageerror", e => console.error("页面错误:", e.message));
page.on("console", m => { if (m.type() === "error") console.error("console:", m.text()); });
await page.goto("file://" + join(HERE, "index.html"), { waitUntil: "load" });
await page.evaluate(() => window.ready);
const DURATION = await page.evaluate(() => window.TIMELINE.durationBeats * 60 / window.TIMELINE.bpm);

const shot = () => page.screenshot({ type: "png", clip: { x: 0, y: 0, width: 1920, height: 1080 }, optimizeForSpeed: true });

if (stills) {
  for (const s of stills.split(",").map(Number)) {
    await page.evaluate(t => window.renderFrame(t), s);
    const buf = await shot();
    const f = join(OUT, `still-${String(s).replace(".", "_")}.png`);
    writeFileSync(f, buf);
    console.log("wrote", f);
  }
  await browser.close();
  process.exit(0);
}

const from = Number(opt("--from", 0)), to = Number(opt("--to", DURATION));
const partial = from > 0 || to < DURATION;
const video = join(OUT, partial ? `part-${from}-${to}.mp4` : "ServerIsland-v0.1.mp4");
const total = Math.round((to - from) * FPS);

// 音乐：响度标准化到 -14 LUFS（视频平台常用）
const ff = spawn("ffmpeg", [
  "-y", "-loglevel", "error",
  "-f", "image2pipe", "-framerate", String(FPS), "-c:v", "png", "-i", "-",
  "-ss", String(from), "-t", String(to - from), "-i", join(OUT, "music.wav"),
  "-filter:a", "loudnorm=I=-14:TP=-1.0:LRA=11",
  "-c:v", "libx264", "-preset", "slow", "-crf", "15", "-pix_fmt", "yuv420p", "-profile:v", "high",
  "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
  "-c:a", "aac", "-b:a", "256k", "-ar", "48000",
  "-movflags", "+faststart", "-shortest", video,
], { stdio: ["pipe", "inherit", "inherit"] });

const t0 = Date.now();
for (let i = 0; i < total; i++) {
  const t = from + i / FPS;
  await page.evaluate(t => window.renderFrame(t), t);
  const buf = await shot();
  if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once("drain", r));
  if (i % 60 === 0 || i === total - 1) {
    const el = (Date.now() - t0) / 1000, eta = el / (i + 1) * (total - i - 1);
    process.stdout.write(`\r帧 ${i + 1}/${total}  ·  ${t.toFixed(1)}s  ·  已用 ${el.toFixed(0)}s  ·  预计剩余 ${eta.toFixed(0)}s   `);
  }
}
ff.stdin.end();
await new Promise(r => ff.on("close", r));
await browser.close();
console.log(`\n✓ ${video}`);
