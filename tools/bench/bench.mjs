// PhotonVision benchmark harness for the Raze (CM5 + OV9782). Driven by raze-bench.sh.
// Node >= 22 (global WebSocket + fetch). No npm install needed: msgpack is vendored.
//
// Phases (each: apply settings -> settle -> WINDOW s of websocket results + device sampling ->
// MJPEG fps window on the processed stream with device sampling):
//   apriltag_<WxH>   AprilTag pipeline at the full-res mode (1280x800)
//   apriltag_<wxh>   AprilTag pipeline at a lower-res mode (640x400, else 640x480)
//   driver_mode      driver mode on (no vision processing), whatever mode driver mode uses
// Original pipeline index / video mode / driver mode are restored at the end (also on Ctrl-C).
import { createRequire } from "node:module";
import { spawn } from "node:child_process";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const { encode, decode } = require("./vendor/msgpack.min.cjs");
const HERE = dirname(fileURLToPath(import.meta.url));

// ---------- args ----------
const args = Object.fromEntries(
  process.argv.slice(2).map((a) => {
    const m = a.match(/^--([^=]+)(?:=(.*))?$/);
    return m ? [m[1], m[2] ?? "1"] : [a, "1"];
  }),
);
const HOST = args.host ?? "172.31.12.81";
const SSH = args.ssh ?? `root@${HOST}`;
const PV_PORT = Number(args["pv-port"] ?? 5800);
const STREAM_PORT = Number(args["stream-port"] ?? 1182);
const WINDOW = Number(args.window ?? 30); // s, pipeline window
const MJPEG_WINDOW = Number(args["mjpeg-window"] ?? 10); // s
const SETTLE = Number(args.settle ?? 6); // s after a settings change
const PROC = args.proc ?? "java";
const LABEL = args.label ?? "unnamed";
const OUT = args.out;
const PHASES = (args.phases ?? "full,low,driver").split(",").filter(Boolean);
const NO_WS = args["no-ws"] === "1"; // for non-PV backends: only system + MJPEG measurements
const CLK_TCK = 100;

const log = (...a) => console.error(`[${new Date().toISOString().slice(11, 19)}]`, ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------- stats ----------
function stats(arr) {
  const v = arr.filter((x) => typeof x === "number" && Number.isFinite(x)).sort((a, b) => a - b);
  if (!v.length) return null;
  const q = (p) => {
    const i = (v.length - 1) * p;
    const lo = Math.floor(i), hi = Math.ceil(i);
    return v[lo] + (v[hi] - v[lo]) * (i - lo);
  };
  const mean = v.reduce((a, b) => a + b, 0) / v.length;
  const r = (x) => Math.round(x * 100) / 100;
  return { n: v.length, mean: r(mean), p50: r(q(0.5)), p95: r(q(0.95)), min: r(v[0]), max: r(v[v.length - 1]) };
}

// ---------- device identity ----------
async function identity() {
  const out = {};
  try {
    const r = await fetch(`http://${HOST}:5899/.well-known/pd-device`, { signal: AbortSignal.timeout(5000) });
    const j = await r.json();
    out.pd_device = { os_version: j.os?.version, os_name: j.os?.name, model: j.model, rev: j.rev, serial: j.serial,
      device_package: j.device_package, slot_active: j.update?.slot_active };
  } catch (e) { out.pd_device_error = String(e); }
  return out;
}

// ---------- device sampler over ssh ----------
function startSampler(seconds) {
  const script = readFileSync(join(HERE, "device-sampler.sh"));
  const p = spawn("ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", SSH, "sh", "-s", "--",
    String(Math.max(2, Math.round(seconds) + 1)), "1", PROC], { stdio: ["pipe", "pipe", "pipe"] });
  p.stdin.end(script);
  let buf = "", err = "";
  p.stdout.on("data", (d) => (buf += d));
  p.stderr.on("data", (d) => (err += d));
  return new Promise((res) => p.on("close", (code) => res(parseSampler(buf, err, code))));
}

function parseSampler(text, err, code) {
  const info = {}; const samples = [];
  for (const line of text.split("\n")) {
    const f = line.split("|");
    if (f[0] === "I") for (const kv of f.slice(1)) { const [k, v] = kv.split("="); info[k] = v; }
    else if (f[0] === "X") info.cmdline = f[1];
    else if (f[0] === "T") (info.top ??= []).push(f.slice(1).join("|").trimEnd());
    else if (f[0] === "S") {
      const cpu = f[2].trim().split(/\s+/).slice(1).map(Number);
      samples.push({ up: +f[1], total: cpu.reduce((a, b) => a + b, 0), idle: cpu[3] + (cpu[4] || 0),
        pid: +f[3], pt: +f[4] + +f[5], rss: +f[6], temp: +f[7] / 1000, thr: f[8],
        clk: info.vcgencmd === "1" ? +f[9] / 1e6 : +f[9] / 1e3, load1: +f[10] });
    }
  }
  const ncpu = Number(info.ncpu) || 4;
  const sys = [], proc = [];
  for (let i = 1; i < samples.length; i++) {
    const a = samples[i - 1], b = samples[i];
    const dt = b.total - a.total;
    if (dt > 0) sys.push(100 * (1 - (b.idle - a.idle) / dt));
    const dup = b.up - a.up;
    if (b.pid && dup > 0) proc.push((100 * (b.pt - a.pt)) / CLK_TCK / dup);
  }
  const thr = [...new Set(samples.map((s) => s.thr))];
  return {
    ok: samples.length > 1, ssh_exit: code, ssh_stderr: err.trim().slice(0, 400) || undefined,
    ncpu, proc_name: info.proc, pid: Number(info.pid) || null, cmdline: info.cmdline, kernel: info.kernel,
    samples: samples.length,
    system_cpu_pct: stats(sys),
    proc_cpu_pct_of_one_core: stats(proc),
    proc_cpu_pct_of_all_cores: stats(proc.map((x) => x / ncpu)),
    proc_rss_mb: stats(samples.filter((s) => s.pid).map((s) => s.rss / 1024)),
    cpu_temp_c: stats(samples.map((s) => s.temp)),
    arm_clock_mhz: stats(samples.map((s) => s.clk)),
    load1: stats(samples.map((s) => s.load1)),
    throttled_values: thr,
    throttled_any: thr.some((t) => t !== "0x0" && t !== "na"),
    top_snapshot_end: info.top,
  };
}

// ---------- MJPEG fps ----------
async function mjpegFps(port, seconds, path = "/stream.mjpg") {
  const url = `http://${HOST}:${port}${path}`;
  const ctl = new AbortController();
  const res = { url, frames: 0 };
  const stamps = []; const sizes = [];
  let bytes = 0;
  try {
    const r = await fetch(url, { signal: ctl.signal });
    res.http_status = r.status;
    res.content_type = r.headers.get("content-type");
    const reader = r.body.getReader();
    const t0 = performance.now();
    const deadline = t0 + seconds * 1000;
    const timer = setTimeout(() => ctl.abort(), seconds * 1000 + 3000);
    // Count JPEG SOI markers (FF D8 FF) — robust to boundary format; carry 2 bytes across chunks.
    let carry = new Uint8Array(0), lastSoiBytes = 0;
    while (performance.now() < deadline) {
      const { value, done } = await reader.read();
      if (done) break;
      const now = performance.now();
      const b = new Uint8Array(carry.length + value.length);
      b.set(carry); b.set(value, carry.length);
      for (let i = 0; i + 2 < b.length; i++) {
        // a match starting inside the 2-byte carry was not countable last chunk (needed 3 bytes)
        if (b[i] === 0xff && b[i + 1] === 0xd8 && b[i + 2] === 0xff) {
          const off = bytes - carry.length + i; // global byte offset of this SOI
          stamps.push(now);
          if (stamps.length > 1) sizes.push(off - lastSoiBytes);
          lastSoiBytes = off;
        }
      }
      bytes += value.length;
      carry = b.slice(Math.max(0, b.length - 2));
    }
    clearTimeout(timer);
    ctl.abort();
    res.frames = stamps.length;
    res.bytes = bytes;
    if (stamps.length > 2) {
      const span = (stamps[stamps.length - 1] - stamps[0]) / 1000;
      res.fps = Math.round(((stamps.length - 1) / span) * 100) / 100;
      const gaps = []; for (let i = 1; i < stamps.length; i++) gaps.push(stamps[i] - stamps[i - 1]);
      res.frame_interval_ms = stats(gaps);
      res.mbit_per_s = Math.round((bytes * 8) / ((performance.now() - t0) / 1000) / 1e4) / 100;
      res.frame_kb = stats(sizes.map((s) => s / 1024));
    }
  } catch (e) {
    if (e.name !== "AbortError") res.error = String(e);
  }
  return res;
}

// ---------- PV websocket ----------
class PV {
  constructor() { this.cams = null; this.results = []; this.recording = false; this.msgCount = 0; this.uid = null; }
  // Two sockets: PV skips the sender when broadcasting selective setting mutations, so commands go
  // out on `ctl` and state is observed on `ws`.
  async connect() {
    this.ctl = new WebSocket(`ws://${HOST}:${PV_PORT}/websocket_data`);
    this.ctl.binaryType = "arraybuffer";
    await new Promise((res, rej) => { this.ctl.onopen = res; this.ctl.onerror = () => rej(new Error("control websocket error")); });
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(`ws://${HOST}:${PV_PORT}/websocket_data`);
      ws.binaryType = "arraybuffer";
      this.ws = ws;
      const to = setTimeout(() => reject(new Error("websocket: no cameraSettings within 10 s")), 10000);
      ws.onerror = (e) => reject(new Error("websocket error " + (e.message ?? "")));
      ws.onmessage = (e) => {
        let d; try { d = decode(new Uint8Array(e.data)); } catch { return; }
        this.msgCount++;
        if (d.settings?.general) this.general = d.settings.general;
        if (d.cameraSettings) {
          this.cams = d.cameraSettings;
          if (!this.uid) this.uid = this.cams[0]?.uniqueName;
          clearTimeout(to); resolve();
        }
        if (d.mutatePipelineSettings && this.cams) {
          const cam = this.cams.find((c) => c.uniqueName === d.mutatePipelineSettings.cameraUniqueName) ?? this.cams[0];
          Object.assign(cam.currentPipelineSettings, d.mutatePipelineSettings);
        }
        const r = d.updatePipelineResult?.[this.uid];
        if (r && this.recording) {
          this.results.push({ t: performance.now(), seq: r.sequenceID, fps: r.fps, latency: r.latency,
            ntargets: r.targets?.length ?? 0, ids: (r.targets ?? []).map((t) => t.fiducialId).filter((x) => x !== undefined && x >= 0) });
        }
      };
    });
  }
  cam() { return this.cams.find((c) => c.uniqueName === this.uid); }
  send(obj) { this.ctl.send(encode(obj)); }
  setPipeline(i) { this.send({ currentPipeline: i, cameraUniqueName: this.uid }); }
  setDriverMode(b) { this.send({ driverMode: b, cameraUniqueName: this.uid }); }
  setSetting(s) { this.send({ changePipelineSetting: { ...s, cameraUniqueName: this.uid } }); }
  snapshot() {
    const c = this.cam(); const s = c.currentPipelineSettings;
    const vm = c.videoFormatList?.[s.cameraVideoModeIndex];
    return { pipelineIndex: c.currentPipelineIndex, pipelineType: s.pipelineType, pipelineNickname: s.pipelineNickname,
      cameraVideoModeIndex: s.cameraVideoModeIndex, videoMode: vm, tagFamily: s.tagFamily, decimate: s.decimate,
      threads: s.threads, blur: s.blur, refineEdges: s.refineEdges, solvePNPEnabled: s.solvePNPEnabled,
      doMultiTarget: s.doMultiTarget, streamingFrameDivisor: s.streamingFrameDivisor, outputShouldDraw: s.outputShouldDraw,
      cameraAutoExposure: s.cameraAutoExposure, cameraExposureRaw: s.cameraExposureRaw, fpsLimit: c.fpsLimit };
  }
  async waitFor(pred, ms = 8000) {
    const t = Date.now();
    while (Date.now() - t < ms) { try { if (pred()) return true; } catch {} await sleep(100); }
    return false;
  }
  summarize(windowS) {
    const r = this.results;
    const out = { ui_messages: r.length };
    if (r.length < 2) return out;
    out.pv_fps = stats(r.map((x) => x.fps));
    out.pv_latency_ms = stats(r.map((x) => x.latency));
    const span = (r[r.length - 1].t - r[0].t) / 1000;
    const dseq = r[r.length - 1].seq - r[0].seq;
    out.seq_delivered_fps = Math.round((dseq / span) * 100) / 100; // frames processed per second from sequenceID
    out.ui_result_rate_hz = Math.round(((r.length - 1) / span) * 100) / 100;
    out.targets = stats(r.map((x) => x.ntargets));
    out.frames_with_targets_pct = Math.round((100 * r.filter((x) => x.ntargets > 0).length) / r.length);
    out.tag_ids_seen = [...new Set(r.flatMap((x) => x.ids))].sort((a, b) => a - b);
    out.window_s = windowS;
    return out;
  }
}

// ---------- main ----------
async function measureWindow(pv, name, extra = {}) {
  log(`[${name}] settle ${SETTLE}s`);
  await sleep(SETTLE * 1000);
  const phase = { name, ...extra };
  if (pv) { phase.pv_state = pv.snapshot(); pv.results = []; pv.recording = true; }
  log(`[${name}] measuring ${WINDOW}s (ws results + device sampler, no stream clients from us)`);
  const sys = await startSampler(WINDOW);
  if (pv) { pv.recording = false; phase.pv = pv.summarize(WINDOW); }
  phase.system = sys;
  log(`[${name}] MJPEG :${STREAM_PORT} for ${MJPEG_WINDOW}s (+ device sampler)`);
  const [mj, sys2] = await Promise.all([mjpegFps(STREAM_PORT, MJPEG_WINDOW), startSampler(MJPEG_WINDOW)]);
  phase.mjpeg_processed = mj;
  phase.system_while_streaming = sys2;
  const p = phase.pv ?? {};
  log(`[${name}] pv_fps=${p.pv_fps?.mean} seq_fps=${p.seq_delivered_fps} lat_p50=${p.pv_latency_ms?.p50} ` +
      `sysCPU=${sys.system_cpu_pct?.mean}% ${PROC}=${sys.proc_cpu_pct_of_one_core?.mean}% mjpeg=${mj.fps}`);
  return phase;
}

async function main() {
  const result = { harness: "raze-bench v1", label: LABEL, host: HOST, started: new Date().toISOString(),
    params: { window_s: WINDOW, mjpeg_window_s: MJPEG_WINDOW, settle_s: SETTLE, proc: PROC, stream_port: STREAM_PORT, phases: PHASES },
    ...(await identity()), phases: [], notes: [] };
  log("image:", result.pd_device?.os_version ?? result.pd_device_error);

  let pv = null, orig = null, restore = async () => {};
  if (!NO_WS) {
    pv = new PV();
    try { await pv.connect(); } catch (e) { result.notes.push("PV websocket unavailable: " + e.message); pv = null; }
  }
  if (pv) {
    await sleep(1500);
    const c = pv.cam();
    orig = { pipelineIndex: c.currentPipelineIndex, ...pv.snapshot() };
    result.pv_general = pv.general;
    result.camera = { nickname: c.nickname, uniqueName: c.uniqueName, path: c.cameraPath, isCSICamera: c.isCSICamera,
      connected: c.isConnected, videoFormatList: c.videoFormatList, fpsLimit: c.fpsLimit, calibrations: (c.calibrations ?? []).length };
    result.original_state = orig;
    log("original:", JSON.stringify({ pipe: orig.pipelineIndex, type: orig.pipelineType, mode: orig.videoMode }));

    let restored = false;
    restore = async () => {
      if (restored) return; restored = true;
      log("restoring original pipeline settings");
      if (orig.pipelineIndex === -1) { pv.setDriverMode(true); return; }
      pv.setDriverMode(false); await sleep(1500);
      pv.setPipeline(orig.pipelineIndex); await sleep(1500);
      pv.setSetting({ cameraVideoModeIndex: orig.cameraVideoModeIndex });
      await pv.waitFor(() => pv.cam().currentPipelineIndex === orig.pipelineIndex &&
        pv.cam().currentPipelineSettings.cameraVideoModeIndex === orig.cameraVideoModeIndex);
    };
    process.on("SIGINT", async () => { await restore(); process.exit(130); });

    // PV 2026 sends videoFormatList as an object keyed by index, 2027 as an array.
    const vfl = c.videoFormatList ?? [];
    const fl = Array.isArray(vfl) ? vfl : Object.keys(vfl).sort((a, b) => a - b).map((k) => vfl[k]);
    const find = (w, h) => fl.findIndex((f) => f.width === w && f.height === h);
    const full = find(1280, 800);
    let low = find(640, 400); if (low < 0) low = find(640, 480);

    // Find an AprilTag pipeline: use the current one if it is AprilTag (Java PipelineType.AprilTag ordinal 5).
    const APRILTAG = 5;
    let atIndex = orig.pipelineType === APRILTAG && orig.pipelineIndex >= 0 ? orig.pipelineIndex : null;
    if (atIndex === null) {
      // walk pipelines looking for AprilTag
      for (let i = 0; i < (c.pipelineNicknames ?? []).length && atIndex === null; i++) {
        pv.setDriverMode(false); pv.setPipeline(i); await sleep(2000);
        if (pv.cam().currentPipelineSettings.pipelineType === APRILTAG) atIndex = i;
      }
    }
    if (atIndex === null) result.notes.push("no AprilTag pipeline found; apriltag phases skipped");
    else if (pv.cam().currentPipelineSettings.tagFamily !== 0) result.notes.push("AprilTag pipeline tagFamily is not 36h11 (0)");

    try {
      for (const ph of PHASES) {
        if ((ph === "full" || ph === "low") && atIndex !== null) {
          const idx = ph === "full" ? full : low;
          if (idx < 0) { result.notes.push(`no video mode for phase ${ph}`); continue; }
          const vm = fl[idx];
          pv.setDriverMode(false); await sleep(500);
          pv.setPipeline(atIndex); await sleep(1000);
          pv.setSetting({ cameraVideoModeIndex: idx });
          const ok = await pv.waitFor(() => pv.cam().currentPipelineSettings.cameraVideoModeIndex === idx && pv.cam().currentPipelineIndex === atIndex);
          if (!ok) result.notes.push(`phase ${ph}: setting confirmation not seen in broadcasts`);
          result.phases.push(await measureWindow(pv, `apriltag_${vm.width}x${vm.height}`,
            { requested_mode: vm, requested_fps: vm.fps }));
        } else if (ph === "driver") {
          pv.setDriverMode(true);
          await pv.waitFor(() => pv.cam().currentPipelineIndex === -1);
          const d = pv.cam(); const vm = d.videoFormatList?.[d.currentPipelineSettings.cameraVideoModeIndex];
          result.phases.push(await measureWindow(pv, "driver_mode", { requested_mode: vm, requested_fps: vm?.fps }));
          pv.setDriverMode(false); await sleep(1000);
        }
      }
    } finally {
      await restore();
      await sleep(1000);
      result.restored_state = pv.snapshot();
      const ok = result.restored_state.pipelineIndex === orig.pipelineIndex &&
        result.restored_state.cameraVideoModeIndex === orig.cameraVideoModeIndex;
      result.restore_ok = ok;
      if (!ok) result.notes.push("WARNING: restore mismatch, check PV UI");
      pv.ws.close(); pv.ctl.close();
    }
  } else {
    // Non-PV backend: just measure system + stream as-is.
    result.phases.push(await measureWindow(null, "as_is"));
  }
  result.finished = new Date().toISOString();
  const json = JSON.stringify(result, null, 2);
  if (OUT) { mkdirSync(dirname(OUT), { recursive: true }); writeFileSync(OUT, json + "\n"); log("wrote", OUT); }
  else process.stdout.write(json + "\n");
  process.exit(0);
}

main().catch((e) => { console.error(e); process.exit(1); });
