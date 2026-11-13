import { audioRevision, bufferToMono, ensureCache, getRate, getSamples } from "./audio";
import { useMelos } from "./store";
import { autoValue, clamp, sectionAt, swungStart } from "./theory";
import type { Expression, Note, Song, Track } from "./types";
import { voicebank, vowelFromLyric } from "./voicebanks";

type Listener = (beat: number, playing: boolean, recording: boolean) => void;

type Strip = {
  input: GainNode;
  filter: BiquadFilterNode;
  shaper: WaveShaperNode;
  lo: BiquadFilterNode;
  mid: BiquadFilterNode;
  hi: BiquadFilterNode;
  comp: DynamicsCompressorNode;
  chorusDry: GainNode;
  chorusWet: GainNode;
  chorusDelay: DelayNode;
  chorusLfo: OscillatorNode;
  chorusDepth: GainNode;
  delayDry: GainNode;
  delayWet: GainNode;
  delayNode: DelayNode;
  delayFb: GainNode;
  spaceWet: GainNode;
  pan: StereoPannerNode;
  fader: GainNode;
  analyser: AnalyserNode;
  lfo: OscillatorNode;
  lfoDepth: GainNode;
};

const listeners = new Set<Listener>();
const liveSources = new Set<AudioScheduledSourceNode>();
const bufferCache = new WeakMap<BaseAudioContext, Map<string, AudioBuffer>>();
const noiseCache = new WeakMap<BaseAudioContext, AudioBuffer>();

let audio: AudioContext | null = null;
let master: GainNode | null = null;
let masterAnalyser: AnalyserNode | null = null;
let strips = new Map<string, Strip>();
let fired = new Set<string>();
let playing = false;
let recording = false;
let cursor = 0;
let origin = 0;
let cycle = 1;
let raf = 0;
let wired = false;
let schedulingLive = true;
let recorder: MediaRecorder | null = null;
let recChunks: Blob[] = [];

const meterScratch = new Uint8Array(1024);

function fillChannel(buffer: AudioBuffer, samples: Float32Array) {
  const channel = new Float32Array(samples.length);
  for (let i = 0; i < samples.length; i++) channel[i] = samples[i] ?? 0;
  buffer.copyToChannel(channel, 0);
}

function emit() {
  for (const fn of listeners) fn(cursor, playing, recording);
}

export function subscribe(fn: Listener) {
  listeners.add(fn);
  return () => {
    listeners.delete(fn);
  };
}

export function isPlaying() {
  return playing;
}

export function isRecording() {
  return recording;
}

export function cursorBeat() {
  return cursor;
}

function songNow() {
  return useMelos.getState().song;
}

function spbOf(song: Song) {
  return 60 / Math.max(20, song.bpm);
}

function context(): AudioContext | null {
  if (typeof window === "undefined") return null;
  if (audio) return audio;
  const AC = window.AudioContext || (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
  if (!AC) return null;
  audio = new AC();
  master = audio.createGain();
  master.gain.value = songNow().master;
  const limiter = audio.createDynamicsCompressor();
  limiter.threshold.value = -2.5;
  limiter.knee.value = 1;
  limiter.ratio.value = 12;
  limiter.attack.value = 0.003;
  limiter.release.value = 0.18;
  masterAnalyser = audio.createAnalyser();
  masterAnalyser.fftSize = 1024;
  master.connect(limiter);
  limiter.connect(masterAnalyser);
  masterAnalyser.connect(audio.destination);
  return audio;
}

function buildStrip(ctx: BaseAudioContext, dest: AudioNode): Strip {
  const input = ctx.createGain();
  const filter = ctx.createBiquadFilter();
  filter.type = "lowpass";
  filter.frequency.value = 1800;
  filter.Q.value = 0.7;
  const shaper = ctx.createWaveShaper();
  shaper.oversample = "2x";
  const lo = ctx.createBiquadFilter();
  lo.type = "lowshelf";
  lo.frequency.value = 180;
  const mid = ctx.createBiquadFilter();
  mid.type = "peaking";
  mid.frequency.value = 1100;
  mid.Q.value = 0.85;
  const hi = ctx.createBiquadFilter();
  hi.type = "highshelf";
  hi.frequency.value = 5200;
  const comp = ctx.createDynamicsCompressor();
  const chorusDry = ctx.createGain();
  const chorusWet = ctx.createGain();
  const chorusDelay = ctx.createDelay(0.08);
  chorusDelay.delayTime.value = 0.016;
  const chorusLfo = ctx.createOscillator();
  chorusLfo.frequency.value = 0.32;
  const chorusDepth = ctx.createGain();
  chorusDepth.gain.value = 0.004;
  chorusLfo.connect(chorusDepth);
  chorusDepth.connect(chorusDelay.delayTime);
  const delayDry = ctx.createGain();
  delayDry.gain.value = 1;
  const delayWet = ctx.createGain();
  const delayNode = ctx.createDelay(1.6);
  const delayFb = ctx.createGain();
  const spaceWet = ctx.createGain();
  const pan = ctx.createStereoPanner();
  const fader = ctx.createGain();
  const analyser = ctx.createAnalyser();
  analyser.fftSize = 1024;
  const lfo = ctx.createOscillator();
  const lfoDepth = ctx.createGain();
  lfoDepth.gain.value = 0;
  lfo.connect(lfoDepth);
  lfoDepth.connect(filter.frequency);

  input.connect(filter);
  filter.connect(shaper);
  shaper.connect(lo);
  lo.connect(mid);
  mid.connect(hi);
  hi.connect(comp);
  comp.connect(chorusDry);
  comp.connect(chorusDelay);
  chorusDelay.connect(chorusWet);
  chorusDry.connect(delayDry);
  chorusWet.connect(delayDry);
  delayDry.connect(delayNode);
  delayNode.connect(delayFb);
  delayFb.connect(delayNode);
  delayNode.connect(delayWet);
  const post = ctx.createGain();
  delayDry.connect(post);
  delayWet.connect(post);
  const spaceDry = ctx.createGain();
  spaceDry.gain.value = 1;
  post.connect(spaceDry);
  const taps = [0.023, 0.031, 0.043, 0.057];
  for (const tap of taps) {
    const delay = ctx.createDelay(0.2);
    delay.delayTime.value = tap;
    const fb = ctx.createGain();
    fb.gain.value = 0.36;
    const level = ctx.createGain();
    level.gain.value = 0.26;
    post.connect(delay);
    delay.connect(fb);
    fb.connect(delay);
    delay.connect(level);
    level.connect(spaceWet);
  }
  spaceDry.connect(pan);
  spaceWet.connect(pan);
  pan.connect(fader);
  fader.connect(analyser);
  analyser.connect(dest);
  const t0 = ctx.currentTime;
  chorusLfo.start(t0);
  lfo.start(t0);
  return {
    input,
    filter,
    shaper,
    lo,
    mid,
    hi,
    comp,
    chorusDry,
    chorusWet,
    chorusDelay,
    chorusLfo,
    chorusDepth,
    delayDry,
    delayWet,
    delayNode,
    delayFb,
    spaceWet,
    pan,
    fader,
    analyser,
    lfo,
    lfoDepth,
  };
}

function driveCurve(amount: number) {
  const n = 257;
  const curve = new Float32Array(n);
  const k = 1 + clamp(amount, 0, 1) * 28;
  for (let i = 0; i < n; i++) {
    const x = (i / (n - 1)) * 2 - 1;
    curve[i] = ((1 + k) * x) / (1 + k * Math.abs(x));
  }
  return curve;
}

function pedalExtras(song: Song, track: Track) {
  let reverb = 0;
  let pitch = 0;
  const expr: Expression = { ...track.expression };
  for (const pedal of song.pedals) {
    if (pedal.status !== "approved" || !pedal.enabled) continue;
    if (pedal.target !== "all" && pedal.target !== track.kind) continue;
    expr.breath = clamp(expr.breath + pedal.breath, 0, 1);
    expr.tension = clamp(expr.tension + pedal.tension, 0, 1);
    expr.formant = clamp(expr.formant + pedal.formant, -1, 1);
    reverb += pedal.reverb;
    pitch += pedal.pitch;
  }
  return { expr, reverb, pitch };
}

function voiced(song: Song, track: Track, beat: number) {
  const extra = pedalExtras(song, track);
  const expr = extra.expr;
  if (song.structureAware) {
    const name = sectionAt(song, beat)?.name.toLowerCase() ?? "";
    if (name.includes("chorus")) {
      expr.energy = clamp(expr.energy + 0.18, 0, 1);
      expr.power = clamp(expr.power + 0.16, 0, 1);
      expr.vibrato = clamp(expr.vibrato + 0.14, 0, 1);
    } else if (name.includes("verse")) {
      expr.breath = clamp(expr.breath + 0.1, 0, 1);
    }
  }
  return { ...extra, expr };
}

function macroValue(track: Track, source: Track["mod"][number]["source"], velocity: number) {
  if (source === "macro1") return track.macros[0] ?? 0.5;
  if (source === "macro2") return track.macros[1] ?? 0.5;
  if (source === "velocity") return velocity;
  return 0.5;
}

function resolved(track: Track, dest: Track["mod"][number]["dest"], base: number, velocity: number) {
  let value = base;
  for (const slot of track.mod) {
    if (slot.source === "lfo" || slot.dest !== dest) continue;
    value += (macroValue(track, slot.source, velocity) - 0.5) * slot.amount;
  }
  return value;
}

function applyDevices(strip: Strip, track: Track, song: Song, time: number) {
  const { reverb } = pedalExtras(song, track);
  const cutoffBase = clamp(track.filter.cutoff, 0, 1);
  const cutoff = clamp(resolved(track, "cutoff", cutoffBase, 0.7), 0, 1);
  const drive = clamp(resolved(track, "drive", track.drive, 0.7), 0, 1);
  const space = clamp(resolved(track, "space", track.space, 0.7) + (track.bypass.space ? 0 : reverb), 0, 1);
  strip.filter.frequency.setTargetAtTime(track.bypass.filter ? 14000 : 70 + cutoff * 7600, time, 0.03);
  strip.filter.Q.setTargetAtTime(track.bypass.filter ? 0.4 : 0.45 + track.filter.resonance * 14, time, 0.03);
  strip.shaper.curve = track.bypass.drive ? null : driveCurve(drive);
  strip.lo.gain.setTargetAtTime(track.bypass.eq ? 0 : track.eq.lo, time, 0.03);
  strip.mid.gain.setTargetAtTime(track.bypass.eq ? 0 : track.eq.mid, time, 0.03);
  strip.hi.gain.setTargetAtTime(track.bypass.eq ? 0 : track.eq.hi, time, 0.03);
  strip.comp.threshold.setTargetAtTime(track.bypass.comp ? 0 : track.comp.threshold, time, 0.03);
  strip.comp.ratio.setTargetAtTime(track.bypass.comp ? 1 : track.comp.ratio, time, 0.03);
  strip.comp.attack.setTargetAtTime(track.bypass.comp ? 0.003 : track.comp.attack, time, 0.03);
  strip.comp.release.setTargetAtTime(track.bypass.comp ? 0.1 : track.comp.release, time, 0.03);
  const chorus = track.bypass.chorus ? 0 : clamp(track.chorus, 0, 1);
  strip.chorusWet.gain.setTargetAtTime(chorus, time, 0.03);
  strip.chorusDry.gain.setTargetAtTime(1 - chorus * 0.25, time, 0.03);
  strip.delayNode.delayTime.setTargetAtTime(clamp(track.delay.time, 0.02, 1.4), time, 0.04);
  strip.delayFb.gain.setTargetAtTime(track.bypass.delay ? 0 : clamp(track.delay.feedback, 0, 0.85), time, 0.03);
  strip.delayWet.gain.setTargetAtTime(track.bypass.delay ? 0 : clamp(track.delay.mix, 0, 1), time, 0.03);
  strip.spaceWet.gain.setTargetAtTime(track.bypass.space ? 0 : space, time, 0.04);
  strip.lfo.frequency.setTargetAtTime(0.08 + track.lfo.rate * 8, time, 0.05);
  let depth = track.lfo.amount * 1600;
  if (!track.bypass.filter) {
    for (const slot of track.mod) {
      if (slot.source === "lfo" && slot.dest === "cutoff") depth += slot.amount * 1100;
    }
  }
  strip.lfoDepth.gain.setTargetAtTime(depth, time, 0.05);
  strip.pan.pan.setTargetAtTime(clamp(track.pan, -1, 1), time, 0.02);
}

function ensureStrips(song: Song, ctx: BaseAudioContext, dest: AudioNode) {
  const ids = new Set(song.tracks.map((track) => track.id));
  for (const [id, strip] of strips) {
    if (ids.has(id)) continue;
    try {
      strip.lfo.stop();
      strip.chorusLfo.stop();
    } catch {
      /* already stopped */
    }
    strip.fader.disconnect();
    strips.delete(id);
  }
  for (const track of song.tracks) {
    if (!strips.has(track.id)) strips.set(track.id, buildStrip(ctx, dest));
  }
}

export function syncAll() {
  const ctx = audio;
  if (!ctx || !master) return;
  const song = songNow();
  ensureStrips(song, ctx, master);
  master.gain.setTargetAtTime(clamp(song.master, 0, 1.2), ctx.currentTime, 0.02);
  const anySolo = song.tracks.some((track) => track.solo);
  for (const track of song.tracks) {
    const strip = strips.get(track.id);
    if (!strip) continue;
    const audible = !track.mute && (!anySolo || track.solo);
    strip.fader.gain.setTargetAtTime(audible ? track.gain : 0, ctx.currentTime, 0.02);
    applyDevices(strip, track, song, ctx.currentTime);
  }
}

function clipBuffer(ctx: BaseAudioContext, id: string) {
  ensureCache(songNow().clips);
  const samples = getSamples(id);
  if (!samples || samples.length < 2) return null;
  let map = bufferCache.get(ctx);
  if (!map) {
    map = new Map();
    bufferCache.set(ctx, map);
  }
  const key = `${id}:${audioRevision()}:${samples.length}`;
  const cached = map.get(key);
  if (cached) return cached;
  const buffer = ctx.createBuffer(1, samples.length, getRate(id));
  fillChannel(buffer, samples);
  map.set(key, buffer);
  return buffer;
}

function noiseBuffer(ctx: BaseAudioContext) {
  const cached = noiseCache.get(ctx);
  if (cached) return cached;
  const length = Math.floor(ctx.sampleRate);
  const buffer = ctx.createBuffer(1, length, ctx.sampleRate);
  const data = new Float32Array(length);
  let state = 17;
  for (let i = 0; i < length; i++) {
    state = (state * 16807) % 2147483647;
    data[i] = (state / 2147483647) * 2 - 1;
  }
  fillChannel(buffer, data);
  noiseCache.set(ctx, buffer);
  return buffer;
}

function arm(node: AudioScheduledSourceNode, when: number) {
  node.start(when);
  if (!schedulingLive) return;
  liveSources.add(node);
  node.onended = () => liveSources.delete(node);
}

function stopSources() {
  const at = audio ? audio.currentTime : 0;
  for (const node of liveSources) {
    try {
      node.stop(at);
    } catch {
      /* already stopped */
    }
  }
  liveSources.clear();
}

function freqOf(pitch: number) {
  return 440 * 2 ** ((pitch - 69) / 12);
}

function gainEnv(ctx: BaseAudioContext, when: number, peak: number, attack: number, hold: number, release: number) {
  const amp = ctx.createGain();
  const safePeak = Math.max(0.001, peak);
  const a = Math.max(0.004, attack);
  const h = Math.max(a + 0.008, hold);
  const e = Math.max(h + 0.02, release);
  amp.gain.setValueAtTime(0.0001, when);
  amp.gain.exponentialRampToValueAtTime(safePeak, when + a);
  amp.gain.exponentialRampToValueAtTime(Math.max(0.001, safePeak * 0.62), when + h);
  amp.gain.exponentialRampToValueAtTime(0.0001, when + e);
  return { amp, end: when + e };
}

function connectSource(node: AudioNode, strip: Strip) {
  node.connect(strip.input);
}

function triggerDrum(ctx: BaseAudioContext, strip: Strip, when: number, pitch: number, velocity: number) {
  const level = clamp(velocity / 127, 0.05, 1);
  if (pitch <= 37) {
    const osc = ctx.createOscillator();
    osc.type = "sine";
    osc.frequency.setValueAtTime(148, when);
    osc.frequency.exponentialRampToValueAtTime(46, when + 0.16);
    const { amp, end } = gainEnv(ctx, when, 0.85 * level, 0.004, 0.08, 0.28);
    osc.connect(amp);
    connectSource(amp, strip);
    arm(osc, when);
    osc.stop(end);
    return;
  }
  if (pitch <= 40) {
    const osc = ctx.createOscillator();
    osc.type = "triangle";
    osc.frequency.value = 186;
    const { amp, end } = gainEnv(ctx, when, 0.35 * level, 0.004, 0.05, 0.16);
    const noise = ctx.createBufferSource();
    noise.buffer = noiseBuffer(ctx);
    const band = ctx.createBiquadFilter();
    band.type = "bandpass";
    band.frequency.value = 1800;
    band.Q.value = 0.7;
    const nGain = ctx.createGain();
    const noiseEnv = gainEnv(ctx, when, 0.45 * level, 0.002, 0.04, 0.14);
    osc.connect(amp);
    noise.connect(band);
    band.connect(nGain);
    nGain.connect(noiseEnv.amp);
    connectSource(amp, strip);
    connectSource(noiseEnv.amp, strip);
    arm(osc, when);
    arm(noise, when);
    osc.stop(end);
    noise.stop(noiseEnv.end);
    return;
  }
  if (pitch < 42) {
    const osc = ctx.createOscillator();
    osc.type = "sine";
    osc.frequency.setValueAtTime(freqOf(pitch) * 0.5, when);
    osc.frequency.exponentialRampToValueAtTime(70, when + 0.18);
    const { amp, end } = gainEnv(ctx, when, 0.55 * level, 0.005, 0.08, 0.24);
    osc.connect(amp);
    connectSource(amp, strip);
    arm(osc, when);
    osc.stop(end);
    return;
  }
  const noise = ctx.createBufferSource();
  noise.buffer = noiseBuffer(ctx);
  const high = ctx.createBiquadFilter();
  high.type = "highpass";
  high.frequency.value = pitch > 46 ? 7000 : 4500;
  const { amp, end } = gainEnv(ctx, when, 0.22 * level, 0.001, 0.02, pitch > 46 ? 0.045 : 0.09);
  noise.connect(high);
  high.connect(amp);
  connectSource(amp, strip);
  arm(noise, when);
  noise.stop(end);
}

function triggerVoice(ctx: BaseAudioContext, strip: Strip, track: Track, song: Song, note: Note, when: number, dur: number) {
  const bank = voicebank(song.voicebank);
  const peaks = bank.vowels[vowelFromLyric(note.lyric)];
  const { expr, pitch } = voiced(song, track, note.start);
  const pitchShift = pitch + resolved(track, "pitch", 0, note.velocity / 127) * 4;
  const freq = freqOf(note.pitch + pitchShift);
  const formantScale = 2 ** (clamp(expr.formant, -12, 12) / 12);
  const src = ctx.createOscillator();
  const body = ctx.createOscillator();
  src.type = bank.source;
  body.type = bank.body;
  src.frequency.setValueAtTime(freq, when);
  body.frequency.setValueAtTime(freq, when);
  body.detune.setValueAtTime(bank.detune, when);
  const vib = ctx.createOscillator();
  vib.frequency.value = 4.2 + expr.energy * 2.2;
  const vibGain = ctx.createGain();
  vibGain.gain.value = freq * (0.003 + expr.vibrato * 0.018);
  vib.connect(vibGain);
  vibGain.connect(src.frequency);
  vibGain.connect(body.frequency);
  const bus = ctx.createGain();
  const sourceMix = ctx.createGain();
  const bodyMix = ctx.createGain();
  sourceMix.gain.value = 0.62;
  bodyMix.gain.value = 0.38;
  src.connect(sourceMix);
  body.connect(bodyMix);
  sourceMix.connect(bus);
  bodyMix.connect(bus);
  const mix = ctx.createGain();
  const qs = [7.5, 9, 8];
  const levels = [0.72, 0.48 + bank.brightness * 0.28, 0.18 + bank.brightness * 0.22];
  peaks.forEach((peakHz, index) => {
    const filter = ctx.createBiquadFilter();
    filter.type = "bandpass";
    filter.frequency.setValueAtTime(Math.max(180, peakHz * formantScale), when);
    filter.Q.value = qs[index] ?? 8;
    const tap = ctx.createGain();
    tap.gain.value = levels[index] ?? 0.3;
    bus.connect(filter);
    filter.connect(tap);
    tap.connect(mix);
  });
  const noise = ctx.createBufferSource();
  noise.buffer = noiseBuffer(ctx);
  noise.loop = true;
  const breathFilter = ctx.createBiquadFilter();
  breathFilter.type = "highpass";
  breathFilter.frequency.value = 1200 + expr.tension * 1600;
  const breath = ctx.createGain();
  breath.gain.value = (0.012 + expr.breath * 0.08) * bank.breath;
  noise.connect(breathFilter);
  breathFilter.connect(breath);
  breath.connect(mix);
  const level = (0.16 + expr.power * 0.2) * bank.gain * clamp(note.velocity / 127, 0.08, 1) * (0.85 + expr.energy * 0.3);
  const attack = bank.attack + (1 - expr.tension) * 0.05;
  const { amp, end } = gainEnv(ctx, when, level, attack, Math.max(attack + 0.05, dur * 0.62), dur);
  mix.connect(amp);
  connectSource(amp, strip);
  arm(src, when);
  arm(body, when);
  arm(noise, when);
  arm(vib, when);
  const stopAt = end + 0.02;
  src.stop(stopAt);
  body.stop(stopAt);
  noise.stop(stopAt);
  vib.stop(stopAt);
}

function triggerTone(ctx: BaseAudioContext, strip: Strip, track: Track, note: Note, when: number, dur: number) {
  const waves: OscillatorType[] = ["triangle", "sawtooth", "square"];
  const osc = ctx.createOscillator();
  const twin = ctx.createOscillator();
  osc.type = waves[Math.round(track.osc.wave)] ?? "sawtooth";
  twin.type = osc.type;
  const base = freqOf(note.pitch + resolved(track, "pitch", 0, note.velocity / 127) * 4);
  osc.frequency.setValueAtTime(base, when);
  twin.frequency.setValueAtTime(base, when);
  osc.detune.setValueAtTime(-track.osc.detune, when);
  twin.detune.setValueAtTime(track.osc.detune, when);
  const peak = (track.kind === "bass" ? 0.34 : track.kind === "pad" ? 0.12 : 0.2) * clamp(note.velocity / 127, 0.05, 1);
  const attack = track.kind === "pad" ? 0.08 : 0.012;
  const { amp, end } = gainEnv(ctx, when, peak, attack, Math.max(attack + 0.04, dur * 0.7), dur + 0.05);
  osc.connect(amp);
  twin.connect(amp);
  connectSource(amp, strip);
  arm(osc, when);
  arm(twin, when);
  osc.stop(end);
  twin.stop(end);
}

function triggerRegion(ctx: BaseAudioContext, strip: Strip, song: Song, region: Track["regions"][number], when: number, spb: number) {
  const buffer = clipBuffer(ctx, region.clipId);
  if (!buffer) return;
  const dur = Math.max(0.05, region.duration * spb);
  const src = ctx.createBufferSource();
  src.buffer = buffer;
  const amp = ctx.createGain();
  const fadeIn = Math.min(Math.max(0.005, region.fadeIn * spb), dur * 0.45);
  const fadeOut = Math.min(Math.max(0.005, region.fadeOut * spb), dur * 0.45);
  const level = Math.max(0.001, region.gain * autoValue(song.tracks.find((t) => t.regions.some((r) => r.id === region.id))?.automation ?? [], region.start, 1));
  amp.gain.setValueAtTime(0.0001, when);
  amp.gain.linearRampToValueAtTime(level, when + fadeIn);
  amp.gain.setValueAtTime(level, Math.max(when + fadeIn, when + dur - fadeOut));
  amp.gain.linearRampToValueAtTime(0.0001, when + dur);
  src.connect(amp);
  connectSource(amp, strip);
  const offset = clamp(region.offset, 0, Math.max(0, buffer.duration - 0.01));
  src.start(when, offset, dur);
  if (schedulingLive) {
    liveSources.add(src);
    src.onended = () => liveSources.delete(src);
  }
}

function triggerNote(ctx: BaseAudioContext, song: Song, track: Track, strip: Strip, note: Note, when: number, spb: number) {
  const dur = Math.max(0.05, note.duration * spb);
  const auto = autoValue(track.automation, note.start, 1);
  const scaled = { ...note, velocity: clamp(note.velocity * auto, 1, 127) };
  if (track.instrument === "pulse" || track.kind === "drums") {
    triggerDrum(ctx, strip, when, note.pitch, scaled.velocity);
    return;
  }
  if (track.voice) {
    triggerVoice(ctx, strip, track, song, scaled, when, dur);
    return;
  }
  if (track.instrument === "fold") {
    const fixed = triggerSampleFixed(ctx, strip, track, scaled, when, dur);
    if (fixed) return;
  }
  triggerTone(ctx, strip, track, scaled, when, dur);
}

function triggerSampleFixed(ctx: BaseAudioContext, strip: Strip, track: Track, note: Note, when: number, dur: number) {
  const id = track.sampleId;
  const buffer = id ? clipBuffer(ctx, id) : null;
  if (!buffer) return false;
  const src = ctx.createBufferSource();
  src.buffer = buffer;
  src.playbackRate.setValueAtTime(2 ** ((note.pitch - 60 + resolved(track, "pitch", 0, note.velocity / 127) * 4) / 12), when);
  const { amp, end } = gainEnv(ctx, when, 0.42 * clamp(note.velocity / 127, 0.05, 1), 0.01, Math.max(0.05, dur * 0.7), dur);
  src.connect(amp);
  connectSource(amp, strip);
  const offset = clamp(track.sampleStart, 0, 0.92) * Math.max(0, buffer.duration - 0.05);
  src.start(when, offset, Math.max(0.03, end - when));
  if (schedulingLive) {
    liveSources.add(src);
    src.onended = () => liveSources.delete(src);
  }
  return true;
}

function click(ctx: BaseAudioContext, when: number, accent: boolean) {
  if (!master || when < ctx.currentTime) return;
  const osc = ctx.createOscillator();
  const amp = ctx.createGain();
  osc.type = "square";
  osc.frequency.value = accent ? 1760 : 1180;
  amp.gain.setValueAtTime(0.0001, when);
  amp.gain.exponentialRampToValueAtTime(accent ? 0.12 : 0.06, when + 0.002);
  amp.gain.exponentialRampToValueAtTime(0.0001, when + 0.035);
  osc.connect(amp);
  amp.connect(master);
  arm(osc, when);
  osc.stop(when + 0.04);
}

function scheduleRange(ctx: BaseAudioContext, from: number, to: number, full: boolean, timeOfBeatZero: number, atCycle: number) {
  if (to <= from) return;
  const song = songNow();
  const spb = spbOf(song);
  ensureCache(song.clips);
  const mark = (key: string) => {
    if (fired.has(key)) return false;
    fired.add(key);
    return true;
  };
  for (const track of song.tracks) {
    const strip = strips.get(track.id);
    if (!strip) continue;
    for (const note of track.notes) {
      const start = swungStart(note.start, song.swing);
      if (start < from || start >= to) continue;
      if (!mark(`${atCycle}:${track.id}:${note.id}`)) continue;
      const when = timeOfBeatZero + start * spb;
      if (!full && when < ctx.currentTime - 0.04) continue;
      const at = Math.max(when, ctx.currentTime);
      triggerNote(ctx, song, track, strip, note, at, spb);
    }
    for (const region of track.regions) {
      if (region.start < from || region.start >= to) continue;
      if (!mark(`${atCycle}:region:${region.id}`)) continue;
      const when = timeOfBeatZero + region.start * spb;
      if (!full && when < ctx.currentTime - 0.04) continue;
      triggerRegion(ctx, strip, song, region, Math.max(when, ctx.currentTime), spb);
    }
  }
  if (!full && song.metronome && master) {
    for (let beat = Math.ceil(from - 0.0001); beat < to; beat++) {
      if (!mark(`${atCycle}:metro:${beat}`)) continue;
      click(ctx, timeOfBeatZero + beat * spb, beat % song.numerator === 0);
    }
  }
}

function pruneFired(minCycle: number) {
  for (const key of fired) {
    const value = Number(key.slice(0, key.indexOf(":")));
    if (value < minCycle) fired.delete(key);
  }
}

function tick() {
  if (!playing || !audio) return;
  const song = songNow();
  const spb = spbOf(song);
  let beat = (audio.currentTime - origin) / spb;
  const loopLen = song.loopEnd - song.loopStart;
  if (song.loopOn && loopLen > 0.05 && beat >= song.loopEnd) {
    const laps = Math.max(1, Math.floor((beat - song.loopStart) / loopLen));
    origin += laps * loopLen * spb;
    cycle += laps;
    beat -= laps * loopLen;
    pruneFired(cycle);
  } else if (!song.loopOn && beat >= song.lengthBeats) {
    playing = false;
    stopSources();
    cursor = 0;
    emit();
    return;
  }
  cursor = Math.max(0, beat);
  const horizon = cursor + 0.28;
  const edge = song.loopOn ? song.loopEnd : song.lengthBeats;
  scheduleRange(audio, Math.max(0, cursor - 0.02), Math.min(horizon, edge), false, origin, cycle);
  if (song.loopOn && loopLen > 0.05 && horizon > song.loopEnd) {
    const overflow = horizon - song.loopEnd;
    scheduleRange(audio, song.loopStart, song.loopStart + overflow, false, origin + loopLen * spb, cycle + 1);
  }
  emit();
}

function ensurePump() {
  if (raf || typeof window === "undefined") return;
  const loop = () => {
    raf = requestAnimationFrame(loop);
    tick();
  };
  raf = requestAnimationFrame(loop);
}

export async function toggle() {
  const ctx = context();
  if (!ctx || !master) return;
  if (ctx.state === "suspended") await ctx.resume();
  syncAll();
  const spb = spbOf(songNow());
  if (playing) {
    playing = false;
    stopSources();
  } else {
    playing = true;
    origin = ctx.currentTime + 0.05 - cursor * spb;
    cycle += 1;
    pruneFired(cycle);
  }
  ensurePump();
  emit();
}

export function stop() {
  playing = false;
  stopSources();
  const song = songNow();
  cursor = song.loopOn ? song.loopStart : 0;
  if (audio) origin = audio.currentTime - cursor * spbOf(song);
  cycle += 1;
  pruneFired(cycle);
  emit();
}

export function seek(beat: number) {
  const song = songNow();
  cursor = clamp(beat, 0, song.lengthBeats);
  cycle += 1;
  pruneFired(cycle);
  if (playing) stopSources();
  if (audio) origin = audio.currentTime + 0.03 - cursor * spbOf(song);
  emit();
}

export async function audition(pitch: number) {
  const ctx = context();
  if (!ctx || !master) return;
  if (ctx.state === "suspended") await ctx.resume();
  syncAll();
  const song = songNow();
  const track = song.tracks.find((item) => item.id === useMelos.getState().ui.trackId) ?? song.tracks[0];
  if (!track) return;
  const strip = strips.get(track.id);
  if (!strip) return;
  const note: Note = { id: "audition", pitch, start: cursor, duration: 0.45, velocity: 104, lyric: "" };
  triggerNote(ctx, song, track, strip, note, ctx.currentTime + 0.02, spbOf(song));
}

export function getMeter(id: string) {
  const analyser = id === "master" ? masterAnalyser : strips.get(id)?.analyser;
  if (!analyser) return 0;
  analyser.getByteTimeDomainData(meterScratch);
  let peak = 0;
  for (let i = 0; i < meterScratch.length; i++) {
    const sample = Math.abs((meterScratch[i] ?? 128) - 128) / 128;
    if (sample > peak) peak = sample;
  }
  return peak;
}

export async function toggleMic() {
  if (recording && recorder && recorder.state !== "inactive") {
    recorder.stop();
    return;
  }
  const ctx = context();
  if (!ctx) throw new Error("Audio is unavailable");
  if (ctx.state === "suspended") await ctx.resume();
  const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  recChunks = [];
  const rec = new MediaRecorder(stream);
  recorder = rec;
  recording = true;
  emit();
  rec.ondataavailable = (event) => {
    if (event.data.size > 0) recChunks.push(event.data);
  };
  rec.onstop = () => {
    recording = false;
    stream.getTracks().forEach((track) => track.stop());
    emit();
    const blob = new Blob(recChunks, { type: rec.mimeType || "audio/webm" });
    void blob.arrayBuffer().then(async (raw) => {
      const decoded = await ctx.decodeAudioData(raw.slice(0));
      useMelos.getState().captureRecording(bufferToMono(decoded), decoded.sampleRate);
    });
  };
  rec.start();
}

async function renderOffline(onlyId: string | null) {
  const song = songNow();
  ensureCache(song.clips);
  const rate = 44100;
  const seconds = song.lengthBeats * spbOf(song) + 1.5;
  const offline = new OfflineAudioContext(2, Math.max(1, Math.ceil(seconds * rate)), rate);
  const offMaster = offline.createGain();
  offMaster.gain.value = song.master;
  const limiter = offline.createDynamicsCompressor();
  limiter.threshold.value = -2.5;
  limiter.ratio.value = 12;
  limiter.attack.value = 0.003;
  limiter.release.value = 0.2;
  offMaster.connect(limiter);
  limiter.connect(offline.destination);
  const previousStrips = strips;
  const previousMaster = master;
  const previousFired = fired;
  strips = new Map();
  master = offMaster;
  fired = new Set();
  schedulingLive = false;
  try {
    const anySolo = song.tracks.some((track) => track.solo);
    for (const track of song.tracks) {
      if (onlyId && track.id !== onlyId) continue;
      const strip = buildStrip(offline, offMaster);
      strips.set(track.id, strip);
      const audible = onlyId ? true : !track.mute && (!anySolo || track.solo);
      strip.fader.gain.value = audible ? track.gain : 0;
      applyDevices(strip, track, song, 0);
    }
    scheduleRange(offline, 0, song.lengthBeats + 0.01, true, 0, 0);
  } finally {
    strips = previousStrips;
    master = previousMaster;
    fired = previousFired;
    schedulingLive = true;
  }
  return offline.startRendering();
}

export function renderMixdown() {
  return renderOffline(null);
}

export function renderTrack(id: string) {
  return renderOffline(id);
}

export function wireEngine() {
  if (wired || typeof window === "undefined") return;
  wired = true;
  useMelos.subscribe((state, prev) => {
    if (state.song !== prev.song && audio) syncAll();
  });
  ensurePump();
}
