// Additive "free voices" layer: rendered vowel multisamples from free UTAU banks.
// The four built-in test banks (voicebanks.ts) and their synth path are untouched.
import { useSyncExternalStore } from "react";
import type { Vowel } from "./voicebanks";

export type FreeVoice = {
  id: string;
  name: string;
  native?: string;
  kind: "samples";
  languages: string[];
  languageNote: string;
  vowels: string[];
  vowelLabels: Record<string, string>;
  license: { summary: string; termsUrl: string; commercial: boolean; attributionRequired: boolean };
  credit: { text: string; url: string };
  source: { name: string; url: string };
};

export type Sample = { buffer: AudioBuffer; midi: number; loopStart: number; loopEnd: number; vowel: string };
export type SampleBank = { voice: FreeVoice; byVowel: Map<string, Sample[]> };
export type LoadState = "idle" | "loading" | "ready" | "error";

type RawManifest = { samples: Record<string, { vowel: string; midi: number; loopStart: number; loopEnd: number; file: string }>; formats: string[] };

const baseUrl = (typeof import.meta !== "undefined" && import.meta.env?.BASE_URL) || "/";
let catalog: FreeVoice[] = [];
let catalogPromise: Promise<FreeVoice[]> | null = null;
const banks = new Map<string, SampleBank>();
const states = new Map<string, LoadState>();
const inflight = new Map<string, Promise<boolean>>();
const listeners = new Set<() => void>();
let version = 0;

function emit() {
  version++;
  for (const fn of listeners) fn();
}

function setState(id: string, state: LoadState) {
  states.set(id, state);
  emit();
}

export function loadFreeCatalog(): Promise<FreeVoice[]> {
  if (!catalogPromise) {
    catalogPromise = fetch(`${baseUrl}voices/catalog.json`, { cache: "no-cache" })
      .then((r) => (r.ok ? r.json() : { voices: [] }))
      .then((j: { voices?: FreeVoice[] }) => {
        catalog = (j.voices ?? []).filter((v) => v && v.kind === "samples");
        emit();
        return catalog;
      })
      .catch(() => {
        catalog = [];
        return catalog;
      });
  }
  return catalogPromise;
}

export function freeVoices() {
  return catalog;
}

export function freeVoice(id: string | undefined) {
  return id ? catalog.find((v) => v.id === id) : undefined;
}

export function isFreeVoiceId(id: string | undefined) {
  // Known before the catalog finishes loading, so saved songs resolve immediately.
  return !!id && (!!freeVoice(id) || id === "ritsu" || id === "kumi");
}

export function loadState(id: string): LoadState {
  return states.get(id) ?? "idle";
}

export function sampleBank(id: string | undefined): SampleBank | null {
  return id ? banks.get(id) ?? null : null;
}

function pickFormat(): "ogg" | "m4a" {
  try {
    const a = document.createElement("audio");
    if (a.canPlayType('audio/ogg; codecs="opus"') !== "") return "ogg";
    if (a.canPlayType("audio/webm; codecs=opus") !== "") return "ogg";
  } catch {
    /* fall through */
  }
  return "m4a";
}

async function decode(raw: ArrayBuffer): Promise<AudioBuffer> {
  const Ctx = (globalThis as unknown as { OfflineAudioContext?: typeof OfflineAudioContext; webkitOfflineAudioContext?: typeof OfflineAudioContext });
  const Off = Ctx.OfflineAudioContext ?? Ctx.webkitOfflineAudioContext!;
  const ctx = new Off(1, 1, 44100);
  return await new Promise<AudioBuffer>((resolve, reject) => {
    const p = ctx.decodeAudioData(raw, resolve, reject);
    if (p && typeof (p as Promise<AudioBuffer>).catch === "function") (p as Promise<AudioBuffer>).catch(reject);
  });
}

export function ensureSampleBank(id: string | undefined): Promise<boolean> {
  if (!id) return Promise.resolve(false);
  if (banks.has(id)) return Promise.resolve(true);
  const running = inflight.get(id);
  if (running) return running;
  const job = (async () => {
    const cat = await loadFreeCatalog();
    const voice = cat.find((v) => v.id === id);
    if (!voice) return false;
    setState(id, "loading");
    try {
      const dir = `${baseUrl}voices/${id}/`;
      const mres = await fetch(`${dir}manifest.json`, { cache: "no-cache" });
      if (!mres.ok) throw new Error(`manifest ${mres.status}`);
      const manifest = (await mres.json()) as RawManifest;
      const preferred = pickFormat();
      const entries = Object.entries(manifest.samples);
      const byVowel = new Map<string, Sample[]>();
      let next = 0;
      const worker = async () => {
        while (next < entries.length) {
          const [, s] = entries[next++]!;
          let buffer: AudioBuffer | null = null;
          for (const fmt of preferred === "ogg" ? ["ogg", "m4a"] : ["m4a", "ogg"]) {
            if (!manifest.formats.includes(fmt)) continue;
            try {
              const r = await fetch(`${dir}${s.file}.${fmt}`);
              if (!r.ok) continue;
              buffer = await decode(await r.arrayBuffer());
              break;
            } catch {
              /* try next format */
            }
          }
          if (!buffer) throw new Error(`sample ${s.file} failed`);
          const list = byVowel.get(s.vowel) ?? [];
          list.push({ buffer, midi: s.midi, loopStart: s.loopStart, loopEnd: s.loopEnd, vowel: s.vowel });
          byVowel.set(s.vowel, list);
        }
      };
      await Promise.all([worker(), worker(), worker(), worker()]);
      for (const list of byVowel.values()) list.sort((a, b) => a.midi - b.midi);
      banks.set(id, { voice, byVowel });
      setState(id, "ready");
      return true;
    } catch (err) {
      console.warn("free voice load failed", id, err);
      setState(id, "error");
      return false;
    } finally {
      inflight.delete(id);
    }
  })();
  inflight.set(id, job);
  return job;
}

export function useFreeVoiceStore() {
  return useSyncExternalStore(
    (fn) => {
      listeners.add(fn);
      return () => listeners.delete(fn);
    },
    () => version,
    () => 0,
  );
}

const KANA_ROWS: Record<Vowel, string> = {
  a: "あかさたなはまやらわがざだばぱぁゃゎ",
  i: "いきしちにひみりぎじぢびぴぃ",
  u: "うくすつぬふむゆるぐずづぶぷぅゅ",
  e: "えけせてねへめれげぜでべぺぇ",
  o: "おこそとのほもよろをごぞどぼぽぉょ",
};

function kanaVowel(s: string): Vowel | null {
  for (let i = s.length - 1; i >= 0; i--) {
    let ch = s[i]!;
    const code = ch.charCodeAt(0);
    if (code >= 0x30a1 && code <= 0x30f6) ch = String.fromCharCode(code - 0x60);
    if (ch === "ー" || ch === "ん") continue;
    for (const v of Object.keys(KANA_ROWS) as Vowel[]) if (KANA_ROWS[v].includes(ch)) return v;
  }
  return null;
}

/** Choose which rendered vowel of a free voice sings a lyric syllable. */
export function voiceVowel(voice: FreeVoice, lyric: string, fallback: Vowel): string {
  const raw = (lyric || "").trim();
  if (voice.languages.includes("ja")) {
    const k = kanaVowel(raw);
    const v = k ?? fallback;
    return voice.vowels.includes(v) ? v : voice.vowels[0]!;
  }
  const s = raw.toLowerCase().replace(/[^a-z]/g, "");
  if (!s) return ({ a: "a", e: "e", i: "ee", o: "aw", u: "oo" } as Record<Vowel, string>)[fallback];
  if (/(ee|ea|ie|ey)/.test(s)) return "ee";
  if (/(oo|ou|ew|ue)/.test(s)) return "oo";
  if (/(oa|ow|aw|au|oh)/.test(s)) return "aw";
  if (/(ah|aa|ar)/.test(s)) return "a";
  if (/(ay|ai|ei)/.test(s)) return "e";
  for (let i = s.length - 1; i >= 0; i--) {
    const c = s[i]!;
    const final = i === s.length - 1;
    if (c === "a") return final ? "a" : "ae";
    if (c === "e") return "e";
    if (c === "i") return "i";
    if (c === "y") return final ? "ee" : "i";
    if (c === "o") return final ? "aw" : "a";
    if (c === "u") return "u";
  }
  return "a";
}

export function nearestSample(bank: SampleBank, vowel: string, midi: number): Sample | null {
  const list = bank.byVowel.get(vowel) ?? bank.byVowel.get(bank.voice.vowels[0]!) ?? [];
  let best: Sample | null = null;
  for (const s of list) if (!best || Math.abs(s.midi - midi) < Math.abs(best.midi - midi)) best = s;
  return best;
}
