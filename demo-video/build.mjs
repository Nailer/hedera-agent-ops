#!/usr/bin/env node
/**
 * Renders demo.mp4 deterministically: narration (Piper TTS) → timeline → frame-by-frame capture of
 * video.html → ffmpeg. Frames are captured by seeking, not by screen-recording, so text stays crisp
 * and audio sync does not drift.
 *
 *   python3 -m pip install piper-tts
 *   PIPER_MODEL=/path/to/en_US-ryan-high.onnx node demo-video/build.mjs
 *
 * Needs ffmpeg and a Playwright-compatible Chromium (PLAYWRIGHT_BROWSERS_PATH or CHROMIUM_PATH).
 */
import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const work = process.env.WORK_DIR ?? join(here, ".build");
const model = process.env.PIPER_MODEL;
const FPS = 24, LEAD = 0.7, TAIL = 1.3;
if (!model) throw new Error("Set PIPER_MODEL to a Piper .onnx voice file");
rmSync(join(work, "frames"), { recursive: true, force: true });
mkdirSync(join(work, "frames"), { recursive: true });

const scenes = JSON.parse(readFileSync(join(here, "narration.json"), "utf8"));
const probe = (f) => parseFloat(execFileSync("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", f]).toString());

let cursor = 0;
const timeline = scenes.map((s) => {
  const wav = join(work, `${s.id}.wav`);
  execFileSync("python3", ["-m", "piper", "-m", model, "-f", wav], { input: s.text, stdio: ["pipe", "ignore", "ignore"] });
  const d = probe(wav);
  const start = cursor;
  cursor += LEAD + d + TAIL;
  return { id: s.id, wav, start, end: cursor, voiceAt: start + LEAD };
});
const total = cursor;
console.log(timeline.map((t) => `${t.id} ${t.start.toFixed(1)}–${t.end.toFixed(1)}`).join("\n"), `\ntotal ${total.toFixed(1)}s`);

// Mix narration onto one track.
const inputs = timeline.flatMap((t) => ["-i", t.wav]);
const filter = timeline.map((t, i) => `[${i}]adelay=${Math.round(t.voiceAt * 1000)}|${Math.round(t.voiceAt * 1000)}[a${i}]`).join(";")
  + ";" + timeline.map((_, i) => `[a${i}]`).join("") + `amix=inputs=${timeline.length}:normalize=0,apad=whole_dur=${total}[out]`;
execFileSync("ffmpeg", ["-y", ...inputs, "-filter_complex", filter, "-map", "[out]", "-t", String(total), join(work, "narration.wav")], { stdio: "ignore" });

const { chromium } = await import(process.env.PLAYWRIGHT_MODULE ?? "playwright");
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_PATH ?? "/opt/pw-browsers/chromium", args: ["--no-sandbox"] });
const ctx = await browser.newContext({ viewport: { width: 1920, height: 1080 } });
// Only the Google Fonts request leaves the machine; route it through node so a proxy-only sandbox works.
await ctx.route((u) => u.protocol.startsWith("http") && !u.href.startsWith("file:"), async (route) => {
  try {
    const r = route.request();
    const res = await fetch(r.url(), { headers: { "user-agent": r.headers()["user-agent"] } });
    const h = Object.fromEntries(res.headers); delete h["content-encoding"]; delete h["content-length"];
    await route.fulfill({ status: res.status, headers: { ...h, "access-control-allow-origin": "*" }, body: Buffer.from(await res.arrayBuffer()) });
  } catch { await route.abort(); }
});
const page = await ctx.newPage();
await page.addInitScript(({ timeline, total }) => { window.TIMELINE = timeline; window.TOTAL = total; }, { timeline, total });
await page.goto(pathToFileURL(join(here, "video.html")).href, { waitUntil: "load" });
await page.evaluate(() => window.ready);

const n = Math.ceil(total * FPS);
for (let i = 0; i < n; i++) {
  await page.evaluate((t) => window.seek(t), i / FPS);
  await page.screenshot({ path: join(work, "frames", `f${String(i).padStart(5, "0")}.jpg`), type: "jpeg", quality: 93 });
  if (i % 240 === 0) console.log(`frame ${i}/${n}`);
}
await browser.close();

const out = resolve(here, "demo.mp4");
execFileSync("ffmpeg", ["-y", "-framerate", String(FPS), "-i", join(work, "frames", "f%05d.jpg"), "-i", join(work, "narration.wav"),
  "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart", out], { stdio: "inherit" });
writeFileSync(join(here, "timeline.json"), JSON.stringify(timeline.map(({ id, start, end }) => ({ id, start, end })), null, 2));
console.log("wrote", out);
