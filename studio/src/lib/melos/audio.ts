import type { Clip } from "./types";
import { clamp1 } from "./theory";

const cache = new Map<string, Float32Array>();
const rates = new Map<string, number>();
const undos = new Map<string, Float32Array[]>();
const redos = new Map<string, Float32Array[]>();
let clipboard: Float32Array | null = null;
let revision = 0;
const listeners = new Set<() => void>();

function touch() {
  revision += 1;
  listeners.forEach((fn) => fn());
}

export function onAudio(fn: () => void) {
  listeners.add(fn);
  return () => {
    listeners.delete(fn);
  };
}

export function audioRevision() {
  return revision;
}

export function resetCache() {
  cache.clear();
  rates.clear();
  undos.clear();
  redos.clear();
  touch();
}

export function encodePcm(samples: Float32Array): string {
  const i16 = new Int16Array(samples.length);
  for (let i = 0; i < samples.length; i++) {
    const s = clamp1(samples[i] ?? 0);
    i16[i] = s < 0 ? s * 0x8000 : s * 0x7fff;
  }
  const bytes = new Uint8Array(i16.buffer);
  let bin = "";
  const size = 8192;
  for (let i = 0; i < bytes.length; i += size) {
    let part = "";
    const end = Math.min(bytes.length, i + size);
    for (let j = i; j < end; j++) part += String.fromCharCode(bytes[j] ?? 0);
    bin += part;
  }
  return btoa(bin);
}

export function decodePcm(pcm: string): Float32Array {
  if (!pcm) return new Float32Array(0);
  const bin = atob(pcm);
  const even = bin.length - (bin.length % 2);
  const bytes = new Uint8Array(even);
  for (let i = 0; i < even; i++) bytes[i] = bin.charCodeAt(i) & 0xff;
  const view = new DataView(bytes.buffer);
  const out = new Float32Array(even / 2);
  for (let i = 0; i < out.length; i++) out[i] = view.getInt16(i * 2, true) / 32768;
  return out;
}

export function ensureCache(clips: Clip[]) {
  for (const clip of clips) {
    if (!cache.has(clip.id)) cache.set(clip.id, clip.pcm ? decodePcm(clip.pcm) : new Float32Array(0));
    rates.set(clip.id, clip.sampleRate);
  }
}

export function getSamples(id: string) {
  return cache.get(id);
}

export function getRate(id: string) {
  return rates.get(id) ?? 44100;
}

export function hasUndo(id: string) {
  return (undos.get(id)?.length ?? 0) > 0;
}

export function hasRedo(id: string) {
  return (redos.get(id)?.length ?? 0) > 0;
}

export function getClipboard() {
  return clipboard;
}

function snapshot(id: string) {
  const cur = cache.get(id);
  if (!cur) return;
  const stack = undos.get(id) ?? [];
  stack.push(new Float32Array(cur));
  if (stack.length > 18) stack.shift();
  undos.set(id, stack);
  redos.set(id, []);
}

export function commitSamples(id: string, data: Float32Array, rate: number, historic = true) {
  if (historic) snapshot(id);
  cache.set(id, data);
  rates.set(id, rate);
  touch();
  return data;
}

export function undoSamples(id: string) {
  const stack = undos.get(id);
  const cur = cache.get(id);
  const prev = stack?.pop();
  if (!prev || !cur) return null;
  const redo = redos.get(id) ?? [];
  redo.push(new Float32Array(cur));
  redos.set(id, redo);
  cache.set(id, prev);
  touch();
  return prev;
}

export function redoSamples(id: string) {
  const stack = redos.get(id);
  const cur = cache.get(id);
  const next = stack?.pop();
  if (!next || !cur) return null;
  const undo = undos.get(id) ?? [];
  undo.push(new Float32Array(cur));
  undos.set(id, undo);
  cache.set(id, next);
  touch();
  return next;
}

export function selection(len: number, a: number, b: number) {
  const start = Math.max(0, Math.min(len, Math.floor(Math.min(a, b))));
  let end = Math.max(0, Math.min(len, Math.floor(Math.max(a, b))));
  if (end <= start) end = Math.min(len, start + 1);
  return { start, end };
}

function mulberry(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function makeTone(freq: number, seconds: number, rate = 22050) {
  const n = Math.max(1, Math.floor(seconds * rate));
  const data = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const t = i / rate;
    const env = Math.min(1, t * 30) * Math.exp(-t * 0.9);
    data[i] =
      Math.sin(2 * Math.PI * freq * t) * 0.42 * env +
      Math.sin(2 * Math.PI * freq * 2 * t) * 0.08 * env;
  }
  return data;
}

export function makeNoise(seconds: number, rate = 22050, seed = 7) {
  const n = Math.max(1, Math.floor(seconds * rate));
  const data = new Float32Array(n);
  const rnd = mulberry(seed);
  let z = 0;
  for (let i = 0; i < n; i++) {
    const white = rnd() * 2 - 1;
    z += 0.08 * (white - z);
    const t = i / n;
    const env = Math.sin(Math.PI * t);
    data[i] = z * 1.8 * env;
  }
  return data;
}

export function makeSilence(seconds: number, rate = 22050) {
  return new Float32Array(Math.max(1, Math.floor(seconds * rate)));
}

export function opAmplify(data: Float32Array, a: number, b: number, gain: number) {
  const next = new Float32Array(data);
  for (let i = a; i < b; i++) next[i] = clamp1((next[i] ?? 0) * gain);
  return next;
}

export function opNormalize(data: Float32Array, a: number, b: number) {
  let peak = 0;
  for (let i = a; i < b; i++) peak = Math.max(peak, Math.abs(data[i] ?? 0));
  const gain = peak > 0.0001 ? 0.98 / peak : 1;
  return opAmplify(data, a, b, gain);
}

export function opSilence(data: Float32Array, a: number, b: number) {
  const next = new Float32Array(data);
  next.fill(0, a, b);
  return next;
}

export function opInvert(data: Float32Array, a: number, b: number) {
  const next = new Float32Array(data);
  for (let i = a; i < b; i++) next[i] = -(next[i] ?? 0);
  return next;
}

export function opReverse(data: Float32Array, a: number, b: number) {
  const next = new Float32Array(data);
  const slice = data.slice(a, b);
  for (let i = 0; i < slice.length; i++) next[a + i] = slice[slice.length - 1 - i] ?? 0;
  return next;
}

export function opFade(data: Float32Array, a: number, b: number, fadeIn: boolean) {
  const next = new Float32Array(data);
  const n = Math.max(1, b - a);
  for (let i = 0; i < n; i++) {
    const g = fadeIn ? i / n : 1 - i / n;
    next[a + i] = (next[a + i] ?? 0) * g;
  }
  return next;
}

export function opTrim(data: Float32Array, a: number, b: number) {
  return data.slice(a, b);
}

export function opCut(data: Float32Array, a: number, b: number) {
  clipboard = data.slice(a, b);
  const next = new Float32Array(data.length - (b - a));
  next.set(data.subarray(0, a), 0);
  next.set(data.subarray(b), a);
  return next;
}

export function opCopy(data: Float32Array, a: number, b: number) {
  clipboard = data.slice(a, b);
}

export function opPaste(data: Float32Array, cursor: number) {
  if (!clipboard || clipboard.length === 0) return data;
  const at = Math.max(0, Math.min(data.length, Math.floor(cursor)));
  const next = new Float32Array(data.length + clipboard.length);
  next.set(data.subarray(0, at), 0);
  next.set(clipboard, at);
  next.set(data.subarray(at), at + clipboard.length);
  return next;
}

export function opEcho(data: Float32Array, a: number, b: number, delaySec: number, rate: number, mix: number) {
  const next = new Float32Array(data);
  const delay = Math.max(1, Math.floor(delaySec * rate));
  for (let i = a; i < b; i++) {
    const j = i - delay;
    const dry = data[i] ?? 0;
    const wet = j >= 0 ? (data[j] ?? 0) : 0;
    next[i] = clamp1(dry + wet * mix);
  }
  return next;
}

export function opResample(data: Float32Array, ratio: number) {
  const safe = Math.max(0.25, Math.min(4, ratio));
  const n = Math.max(1, Math.floor(data.length / safe));
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const x = i * safe;
    const i0 = Math.floor(x);
    const i1 = Math.min(data.length - 1, i0 + 1);
    const f = x - i0;
    out[i] = (data[i0] ?? 0) * (1 - f) + (data[i1] ?? 0) * f;
  }
  return out;
}

export function opPitchKeep(data: Float32Array, semitones: number) {
  const ratio = 2 ** (semitones / 12);
  const grain = 1024;
  const hopOut = 512;
  const hopIn = Math.max(1, Math.floor(hopOut * ratio));
  const out = new Float32Array(data.length);
  for (let pos = 0, src = 0; pos < out.length; pos += hopOut, src += hopIn) {
    for (let i = 0; i < grain && pos + i < out.length; i++) {
      const window = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / grain);
      const idx = Math.min(data.length - 1, src + Math.floor(i * ratio));
      out[pos + i] = (out[pos + i] ?? 0) + (data[idx] ?? 0) * window * 0.55;
    }
  }
  return out;
}

export function opEq(data: Float32Array, a: number, b: number, loDb: number, hiDb: number) {
  const next = new Float32Array(data);
  const loG = 10 ** (loDb / 20);
  const hiG = 10 ** (hiDb / 20);
  let low = 0;
  for (let i = a; i < b; i++) {
    const x = data[i] ?? 0;
    low += 0.08 * (x - low);
    const high = x - low;
    next[i] = clamp1(low * loG + high * hiG);
  }
  return next;
}

export function profileRms(data: Float32Array, a: number, b: number) {
  let acc = 0;
  const n = Math.max(1, b - a);
  for (let i = a; i < b; i++) acc += (data[i] ?? 0) ** 2;
  return Math.sqrt(acc / n);
}

export function opNoiseReduce(data: Float32Array, a: number, b: number, floor: number) {
  const next = new Float32Array(data);
  const thresh = Math.max(0.002, floor * 2.2);
  for (let i = a; i < b; i++) {
    const s = next[i] ?? 0;
    if (Math.abs(s) < thresh) next[i] = s * 0.12;
  }
  return next;
}

export function opDeclick(data: Float32Array, a: number, b: number) {
  const next = new Float32Array(data);
  for (let i = Math.max(1, a); i < Math.min(data.length - 1, b); i++) {
    const s = data[i] ?? 0;
    const p = data[i - 1] ?? 0;
    const n = data[i + 1] ?? 0;
    if (Math.abs(s) > 0.85 && Math.abs(p) < 0.35 && Math.abs(n) < 0.35) next[i] = (p + n) / 2;
  }
  return next;
}

export function peaksOf(data: Float32Array, buckets: number) {
  const out: number[] = [];
  const spp = Math.max(1, data.length / buckets);
  for (let i = 0; i < buckets; i++) {
    let peak = 0;
    const a = Math.floor(i * spp);
    const b = Math.min(data.length, Math.floor((i + 1) * spp));
    for (let j = a; j < b; j++) peak = Math.max(peak, Math.abs(data[j] ?? 0));
    out.push(peak);
  }
  return out;
}

export function fftMag(time: Float32Array) {
  const n = time.length;
  const re = Float32Array.from(time);
  const im = new Float32Array(n);
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      const tr = re[i] ?? 0;
      re[i] = re[j] ?? 0;
      re[j] = tr;
      const ti = im[i] ?? 0;
      im[i] = im[j] ?? 0;
      im[j] = ti;
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = (-2 * Math.PI) / len;
    const wlenRe = Math.cos(ang);
    const wlenIm = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let wr = 1;
      let wi = 0;
      for (let j = 0; j < len / 2; j++) {
        const uRe = re[i + j] ?? 0;
        const uIm = im[i + j] ?? 0;
        const xRe = re[i + j + len / 2] ?? 0;
        const xIm = im[i + j + len / 2] ?? 0;
        const vRe = xRe * wr - xIm * wi;
        const vIm = xRe * wi + xIm * wr;
        re[i + j] = uRe + vRe;
        im[i + j] = uIm + vIm;
        re[i + j + len / 2] = uRe - vRe;
        im[i + j + len / 2] = uIm - vIm;
        const nwr = wr * wlenRe - wi * wlenIm;
        wi = wr * wlenIm + wi * wlenRe;
        wr = nwr;
      }
    }
  }
  const half = n / 2;
  const mag = new Float32Array(half);
  for (let i = 0; i < half; i++) mag[i] = Math.min(1, Math.hypot(re[i] ?? 0, im[i] ?? 0) / n * 10);
  return mag;
}

export function encodeWav(interleaved: Float32Array, rate: number, channels: number) {
  const samples = interleaved.length;
  const block = channels * 2;
  const buffer = new ArrayBuffer(44 + samples * 2);
  const view = new DataView(buffer);
  const write = (offset: number, text: string) => {
    for (let i = 0; i < text.length; i++) view.setUint8(offset + i, text.charCodeAt(i));
  };
  write(0, "RIFF");
  view.setUint32(4, 36 + samples * 2, true);
  write(8, "WAVE");
  write(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, channels, true);
  view.setUint32(24, rate, true);
  view.setUint32(28, rate * block, true);
  view.setUint16(32, block, true);
  view.setUint16(34, 16, true);
  write(36, "data");
  view.setUint32(40, samples * 2, true);
  let offset = 44;
  for (let i = 0; i < samples; i++) {
    const s = clamp1(interleaved[i] ?? 0);
    view.setInt16(offset, s < 0 ? s * 0x8000 : s * 0x7fff, true);
    offset += 2;
  }
  return new Blob([buffer], { type: "audio/wav" });
}

export function monoWav(data: Float32Array, rate: number) {
  return encodeWav(data, rate, 1);
}

export function downloadBlob(blob: Blob, filename: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

export function bufferToMono(buffer: AudioBuffer) {
  const left = buffer.getChannelData(0);
  if (buffer.numberOfChannels < 2) return new Float32Array(left);
  const right = buffer.getChannelData(1);
  const out = new Float32Array(left.length);
  for (let i = 0; i < left.length; i++) out[i] = ((left[i] ?? 0) + (right[i] ?? 0)) / 2;
  return out;
}

export function stereoInterleave(buffer: AudioBuffer) {
  const left = buffer.getChannelData(0);
  const right = buffer.numberOfChannels > 1 ? buffer.getChannelData(1) : left;
  const out = new Float32Array(left.length * 2);
  for (let i = 0; i < left.length; i++) {
    out[i * 2] = left[i] ?? 0;
    out[i * 2 + 1] = right[i] ?? 0;
  }
  return out;
}
