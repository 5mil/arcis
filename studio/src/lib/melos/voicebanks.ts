export type Vowel = "a" | "e" | "i" | "o" | "u";

export type Voicebank = {
  id: string;
  name: string;
  credit: string;
  source: OscillatorType;
  body: OscillatorType;
  detune: number;
  breath: number;
  brightness: number;
  attack: number;
  gain: number;
  vowels: Record<Vowel, [number, number, number]>;
};

const BASE: Record<Vowel, [number, number, number]> = {
  a: [730, 1090, 2440],
  e: [530, 1840, 2480],
  i: [390, 1990, 2550],
  o: [570, 840, 2410],
  u: [440, 1020, 2240],
};

function shift(scale: number): Record<Vowel, [number, number, number]> {
  const out = {} as Record<Vowel, [number, number, number]>;
  for (const key of Object.keys(BASE) as Vowel[]) {
    const row = BASE[key];
    out[key] = [row[0] * scale, row[1] * scale, row[2] * scale];
  }
  return out;
}

export const TEST_BANKS: Voicebank[] = [
  {
    id: "lamp",
    name: "Lamp",
    credit: "Melos test bank · warm",
    source: "sawtooth",
    body: "triangle",
    detune: 7,
    breath: 0.35,
    brightness: 0.55,
    attack: 0.03,
    gain: 1,
    vowels: BASE,
  },
  {
    id: "reed",
    name: "Reed",
    credit: "Melos test bank · airy",
    source: "triangle",
    body: "sine",
    detune: 4,
    breath: 0.82,
    brightness: 0.28,
    attack: 0.07,
    gain: 1.15,
    vowels: shift(0.94),
  },
  {
    id: "glass",
    name: "Glass",
    credit: "Melos test bank · bright",
    source: "sawtooth",
    body: "square",
    detune: 12,
    breath: 0.12,
    brightness: 0.9,
    attack: 0.012,
    gain: 0.72,
    vowels: shift(1.14),
  },
  {
    id: "clay",
    name: "Clay",
    credit: "Melos test bank · dark",
    source: "triangle",
    body: "sine",
    detune: 2,
    breath: 0.22,
    brightness: 0.18,
    attack: 0.05,
    gain: 1.2,
    vowels: shift(0.8),
  },
];

export function voicebank(id: string | undefined): Voicebank {
  return TEST_BANKS.find((bank) => bank.id === id) ?? TEST_BANKS[0]!;
}

export function vowelFromLyric(lyric: string): Vowel {
  const s = lyric.toLowerCase();
  if (/(oo|ue|ew)/.test(s)) return "u";
  if (/(ee|ea|ie)/.test(s)) return "i";
  if (/(oh|oa|ow)/.test(s)) return "o";
  if (/(ah|aa)/.test(s)) return "a";
  for (let i = s.length - 1; i >= 0; i--) {
    const c = s[i];
    if (c === "a") return "a";
    if (c === "e") return "e";
    if (c === "i" || c === "y") return "i";
    if (c === "o") return "o";
    if (c === "u") return "u";
  }
  return "a";
}
