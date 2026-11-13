export type MusicalMode = "major" | "minor";
export type TrackKind = "vocal" | "harmony" | "bass" | "drums" | "pad" | "audio";
export type Instrument = "filament" | "pulse" | "fold";
export type StudioMode = "song" | "rack" | "mix" | "wave" | "live";
export type WaveView = "wave" | "spectrum";
export type VocalEngine = "vocaloid" | "synthv" | "ace" | "emvoice";
export type ModSource = "lfo" | "macro1" | "macro2" | "velocity";
export type ModDest = "cutoff" | "pitch" | "drive" | "space";

export type Note = {
  id: string;
  pitch: number;
  start: number;
  duration: number;
  velocity: number;
  lyric: string;
};

export type Expression = {
  breath: number;
  tension: number;
  power: number;
  energy: number;
  vibrato: number;
  formant: number;
};

export type Bypass = {
  filter: boolean;
  drive: boolean;
  eq: boolean;
  comp: boolean;
  chorus: boolean;
  delay: boolean;
  space: boolean;
};

export type AutoPoint = { id: string; beat: number; value: number };

export type Region = {
  id: string;
  clipId: string;
  start: number;
  duration: number;
  offset: number;
  gain: number;
  fadeIn: number;
  fadeOut: number;
};

export type ModSlot = { source: ModSource; dest: ModDest; amount: number };

export type Track = {
  id: string;
  name: string;
  kind: TrackKind;
  instrument: Instrument;
  voice: boolean;
  gain: number;
  pan: number;
  mute: boolean;
  solo: boolean;
  notes: Note[];
  expression: Expression;
  eq: { lo: number; mid: number; hi: number };
  comp: { threshold: number; ratio: number; attack: number; release: number };
  filter: { cutoff: number; resonance: number };
  osc: { wave: number; detune: number };
  drive: number;
  chorus: number;
  delay: { time: number; feedback: number; mix: number };
  space: number;
  lfo: { rate: number; amount: number };
  macros: [number, number, number, number];
  mod: [ModSlot, ModSlot];
  bypass: Bypass;
  automation: AutoPoint[];
  regions: Region[];
  sampleId: string | null;
  sampleStart: number;
};

export type Section = { id: string; name: string; start: number; bars: number };

export type Clip = {
  id: string;
  name: string;
  sampleRate: number;
  pcm: string;
};

export type Marker = { id: string; clipId: string; sample: number; text: string };

export type Pedal = {
  id: string;
  name: string;
  author: string;
  target: TrackKind | "all";
  breath: number;
  tension: number;
  pitch: number;
  reverb: number;
  formant: number;
  status: "pending" | "approved" | "rejected";
  enabled: boolean;
};

export type PromptEvent = { id: string; text: string; effect: string };

export type Song = {
  title: string;
  bpm: number;
  tonic: number;
  mode: MusicalMode;
  numerator: number;
  denominator: number;
  lengthBeats: number;
  loopStart: number;
  loopEnd: number;
  loopOn: boolean;
  metronome: boolean;
  swing: number;
  structureAware: boolean;
  master: number;
  tracks: Track[];
  sections: Section[];
  clips: Clip[];
  markers: Marker[];
  pedals: Pedal[];
  prompts: PromptEvent[];
  vocalEngine: VocalEngine;
  voicebank: string;
  kickChannel: string;
};

export const EXPR: Expression = {
  breath: 0.22,
  tension: 0.34,
  power: 0.55,
  energy: 0.5,
  vibrato: 0.26,
  formant: 0,
};

export const BYPASS: Bypass = {
  filter: false,
  drive: false,
  eq: false,
  comp: false,
  chorus: false,
  delay: false,
  space: false,
};

export function blankTrack(
  partial: Pick<Track, "id" | "name" | "kind"> & Partial<Track>,
): Track {
  const kind = partial.kind;
  return {
    instrument: kind === "drums" ? "pulse" : kind === "audio" ? "fold" : "filament",
    voice: kind === "vocal" || kind === "harmony",
    gain: kind === "drums" ? 0.7 : 0.82,
    pan: 0,
    mute: false,
    solo: false,
    notes: [],
    expression: { ...EXPR },
    eq: { lo: 0, mid: 0, hi: 0 },
    comp: { threshold: -16, ratio: 2.2, attack: 0.012, release: 0.18 },
    filter: { cutoff: kind === "bass" ? 0.42 : 0.72, resonance: 0.35 },
    osc: { wave: kind === "pad" ? 0 : 1, detune: kind === "pad" ? 10 : 4 },
    drive: kind === "bass" ? 0.18 : 0.06,
    chorus: kind === "pad" ? 0.28 : 0.06,
    delay: { time: 0.3, feedback: 0.28, mix: kind === "vocal" ? 0.14 : 0.08 },
    space: kind === "vocal" ? 0.22 : 0.12,
    lfo: { rate: 0.25, amount: 0 },
    macros: [0.5, 0.5, 0.4, 0.3],
    mod: [
      { source: "lfo", dest: "cutoff", amount: 0.18 },
      { source: "macro1", dest: "drive", amount: 0.45 },
    ],
    bypass: { ...BYPASS },
    automation: [],
    regions: [],
    sampleId: null,
    sampleStart: 0,
    ...partial,
  };
}
