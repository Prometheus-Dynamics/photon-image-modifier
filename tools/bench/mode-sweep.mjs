// Every video mode of the first camera, one after another: delivered fps (from result sequence
// ids), PhotonVision's latency, system CPU (/proc/stat over SSH) and one raw and one processed
// MJPEG frame per mode (saved, with its size, to spot black frames).
//
//   node tools/bench/mode-sweep.mjs [--host=172.31.12.81] [--window=8] [--out=DIR]
//
// Restores the original video mode at the end. Node >= 22 (global WebSocket and fetch).
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const require = createRequire(import.meta.url);
const { encode, decode } = require("./vendor/msgpack.min.cjs");

const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `=${d}`).split("=").slice(1).join("=");
const HOST = arg("host", "172.31.12.81");
const WINDOW = Number(arg("window", 8));
const OUT = arg("out", new URL("./results/mode-sweep", import.meta.url).pathname);
mkdirSync(OUT, { recursive: true });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const stats = (xs) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const q = (p) => s[Math.min(s.length - 1, Math.floor(p * s.length))];
  return { n: s.length, mean: +(s.reduce((a, b) => a + b, 0) / s.length).toFixed(2), p50: +q(0.5).toFixed(2), p95: +q(0.95).toFixed(2), max: +s[s.length - 1].toFixed(2) };
};
const cpuSnap = () => {
  const line = execFileSync("ssh", ["-o", "BatchMode=yes", `root@${HOST}`, "head -1 /proc/stat"]).toString().trim().split(/\s+/).slice(1).map(Number);
  const idle = line[3] + line[4];
  return { idle, total: line.reduce((a, b) => a + b, 0) };
};

// One JPEG out of an MJPEG stream (the first complete frame after `skip` frames).
async function grabJpeg(port, skip = 3) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 6000);
  try {
    const res = await fetch(`http://${HOST}:${port}/stream.mjpg`, { signal: ctl.signal });
    const reader = res.body.getReader();
    let buf = Buffer.alloc(0);
    let seen = 0;
    for (;;) {
      const { value, done } = await reader.read();
      if (done) return null;
      buf = Buffer.concat([buf, Buffer.from(value)]);
      const start = buf.indexOf(Buffer.from([0xff, 0xd8]));
      const end = start >= 0 ? buf.indexOf(Buffer.from([0xff, 0xd9]), start + 2) : -1;
      if (start >= 0 && end > 0) {
        const jpeg = buf.subarray(start, end + 2);
        buf = buf.subarray(end + 2);
        if (seen++ >= skip) {
          ctl.abort();
          return jpeg;
        }
      }
    }
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

const ws = new WebSocket(`ws://${HOST}:5800/websocket_data`);
ws.binaryType = "arraybuffer";
let cam = null;
const results = [];
ws.onmessage = (e) => {
  const d = decode(new Uint8Array(e.data));
  if (d.cameraSettings?.length) cam = d.cameraSettings[0];
  if (d.updatePipelineResult && cam) {
    const r = d.updatePipelineResult[cam.uniqueName];
    if (r) results.push({ t: Date.now(), ...r });
  }
};
await new Promise((r) => (ws.onopen = r));
for (let i = 0; i < 50 && !cam; i++) await sleep(100);
if (!cam) throw new Error("no camera settings from PhotonVision");
const uid = cam.uniqueName;
const send = (o) => ws.send(encode(o));
const vfl = cam.videoFormatList;
const modes = Array.isArray(vfl) ? vfl : Object.keys(vfl).sort((a, b) => a - b).map((k) => vfl[k]);
const original = cam.currentPipelineSettings.cameraVideoModeIndex;
console.log(`camera ${cam.nickname}, ${modes.length} modes, pipeline type ${cam.currentPipelineSettings.pipelineType}`);

const rows = [];
for (let idx = 0; idx < modes.length; idx++) {
  const m = modes[idx];
  const label = `${m.width}x${m.height}@${m.fps}`;
  send({ changePipelineSetting: { cameraVideoModeIndex: idx, cameraUniqueName: uid } });
  await sleep(4000);
  results.length = 0;
  const c0 = cpuSnap();
  await sleep(WINDOW * 1000);
  const c1 = cpuSnap();
  const win = results.slice();
  const seqs = win.map((r) => r.sequenceID).filter((s) => s != null);
  const span = win.length > 1 ? (win[win.length - 1].t - win[0].t) / 1000 : 0;
  const deliveredFps = seqs.length > 1 && span > 0 ? +((seqs[seqs.length - 1] - seqs[0]) / span).toFixed(1) : 0;
  const cpu = +(100 * (1 - (c1.idle - c0.idle) / (c1.total - c0.total))).toFixed(1);
  const raw = await grabJpeg(1181);
  const processed = await grabJpeg(1182);
  if (raw) writeFileSync(join(OUT, `${label}-raw.jpg`), raw);
  if (processed) writeFileSync(join(OUT, `${label}-processed.jpg`), processed);
  const row = {
    mode: label,
    delivered_fps: deliveredFps,
    latency_ms: stats(win.map((r) => r.latency).filter((x) => x > 0)),
    system_cpu_pct: cpu,
    targets_max: Math.max(0, ...win.map((r) => r.targets?.length ?? 0)),
    raw_jpeg_kb: raw ? +(raw.length / 1024).toFixed(1) : null,
    processed_jpeg_kb: processed ? +(processed.length / 1024).toFixed(1) : null,
  };
  rows.push(row);
  console.log(JSON.stringify(row));
}
send({ changePipelineSetting: { cameraVideoModeIndex: original, cameraUniqueName: uid } });
await sleep(1500);
writeFileSync(join(OUT, "sweep.json"), JSON.stringify({ host: HOST, camera: cam.nickname, rows }, null, 2));
console.log(`wrote ${join(OUT, "sweep.json")}`);
process.exit(0);
