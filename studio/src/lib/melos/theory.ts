import type { Expression, Note, Section, Song, Track } from "./types";

export const NOTE_NAMES = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"] as const;

export const KEY_MAP: Record<string, number> = {
  a: 0,
  w: 1,
  s: 2,
  e: 3,
  d: 4,
  f: 5,
  t: 6,
  g: 7,
  y: 8,
  h: 9,
  u: 10,
  j: 11,
  k: 12,
};

export function clamp(n: number, lo: number, hi: number) {
  return Math.max(lo, Math.min(hi, n));
}

export function clamp01(n: number) {
  return clamp(n, 0, 1);
}

export function clamp1(n: number) {
  return clamp(n, -1, 1);
}

export function uid(prefix: string) {
  return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 7)}`;
}

export function scalePcs(tonic: number, mode: "major" | "minor") {
  const steps = mode === "major" ? [0, 2, 4, 5, 7, 9, 11] : [0, 2, 3, 5, 7, 8, 10];
  return steps.map((s) => (tonic + s) % 12);
}

export function stepScale(pitch: number, dir: number, pcs: number[]) {
  let p = pitch + (dir >= 0 ? 1 : -1);
  const sign = dir >= 0 ? 1 : -1;
  for (let i = 0; i < 12; i++) {
    const pc = ((p % 12) + 12) % 12;
    if (pcs.includes(pc)) return clamp(p, 24, 108);
    p += sign;
  }
  return pitch;
}

export function pitchName(pitch: number) {
  const pc = ((pitch % 12) + 12) % 12;
  const oct = Math.floor(pitch / 12) - 1;
  return `${NOTE_NAMES[pc]}${oct}`;
}

export function formatClock(beat: number, numerator: number) {
  const safe = Math.max(0, beat);
  const bar = Math.floor(safe / numerator) + 1;
  const inside = safe - (bar - 1) * numerator;
  const b = Math.floor(inside) + 1;
  const ticks = Math.floor((inside - Math.floor(inside)) * 100);
  return `${bar}.${b}.${ticks.toString().padStart(2, "0")}`;
}

export function gainLabel(g: number) {
  if (g <= 0.001) return "−∞";
  const db = 20 * Math.log10(g);
  return `${db.toFixed(1)} dB`;
}

export function sectionAt(song: Song, beat: number): Section | undefined {
  const barBeats = song.numerator;
  return song.sections.find((s) => beat >= s.start && beat < s.start + s.bars * barBeats);
}

export function quantizeBeat(beat: number, grid: number) {
  return Math.max(0, Math.round(beat / grid) * grid);
}

export function swungStart(start: number, swing: number) {
  if (swing <= 0.001) return start;
  const idx = Math.round(start / 0.5);
  if (idx % 2 === 1) return start + swing * 0.1;
  return start;
}

export function autoValue(points: { beat: number; value: number }[], beat: number, fallback: number) {
  if (points.length === 0) return fallback;
  const sorted = [...points].sort((a, b) => a.beat - b.beat);
  const first = sorted[0];
  if (!first || beat <= first.beat) return first?.value ?? fallback;
  const last = sorted[sorted.length - 1];
  if (!last || beat >= last.beat) return last?.value ?? fallback;
  for (let i = 0; i < sorted.length - 1; i++) {
    const a = sorted[i];
    const b = sorted[i + 1];
    if (!a || !b) continue;
    if (beat >= a.beat && beat <= b.beat) {
      const t = (beat - a.beat) / Math.max(0.0001, b.beat - a.beat);
      return a.value + (b.value - a.value) * t;
    }
  }
  return fallback;
}

export function interpretPrompt(text: string): {
  effect: string;
  patch: Partial<Expression>;
  semitones: number;
  density: "busy" | "sparse" | "none";
} {
  const t = text.toLowerCase();
  const patch: Partial<Expression> = {};
  let semitones = 0;
  let density: "busy" | "sparse" | "none" = "none";
  const bits: string[] = [];
  if (/breath|air|whisper|intimate|soft air/.test(t)) {
    patch.breath = 0.22;
    bits.push("breath");
  }
  if (/fry|tense|grit|strain/.test(t)) {
    patch.tension = 0.2;
    bits.push("tension");
  }
  if (/power|belt|strong|lift|bigger/.test(t)) {
    patch.power = 0.18;
    patch.energy = 0.12;
    bits.push("power");
  }
  if (/soft|quiet|gentle|hush/.test(t)) {
    patch.power = -0.18;
    patch.breath = 0.12;
    bits.push("softer");
  }
  if (/energy|hype|push|bright/.test(t)) {
    patch.energy = 0.2;
    bits.push("energy");
  }
  if (/dark/.test(t)) {
    patch.formant = -1.4;
    patch.tension = 0.08;
    bits.push("darker");
  }
  if (/smile|brighter|forward/.test(t)) {
    patch.formant = 1.3;
    bits.push("brighter");
  }
  if (/vibrato|wider/.test(t)) {
    patch.vibrato = 0.22;
    bits.push("vibrato");
  }
  if (/higher|up a|transpose up/.test(t)) {
    semitones = 2;
    bits.push("higher");
  }
  if (/lower|down a|transpose down/.test(t)) {
    semitones = -2;
    bits.push("lower");
  }
  if (/busier|dense|more notes|fill/.test(t)) {
    density = "busy";
    bits.push("denser");
  }
  if (/sparse|space out|fewer|strip/.test(t)) {
    density = "sparse";
    bits.push("sparser");
  }
  if (bits.length === 0) {
    patch.energy = 0.08;
    bits.push("energy nudge");
  }
  return { effect: bits.join(" · "), patch, semitones, density };
}

export function applyDensity(notes: Note[], section: Section, barBeats: number, density: "busy" | "sparse" | "none") {
  if (density === "none") return notes;
  const end = section.start + section.bars * barBeats;
  const inside = (n: Note) => n.start >= section.start && n.start < end;
  if (density === "sparse") {
    let seen = 0;
    return notes.filter((n) => {
      if (!inside(n)) return true;
      seen += 1;
      return seen % 2 === 1;
    });
  }
  const next: Note[] = [];
  for (const n of notes) {
    if (!inside(n) || n.duration < 1) {
      next.push(n);
      continue;
    }
    const half = n.duration / 2;
    next.push({ ...n, duration: half });
    next.push({
      ...n,
      id: uid("n"),
      start: n.start + half,
      duration: half,
      pitch: n.pitch,
      lyric: "—",
    });
  }
  return next;
}

export function vocalTrack(song: Song): Track | undefined {
  return song.tracks.find((t) => t.kind === "vocal");
}
