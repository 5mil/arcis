import { create } from "zustand";
import { persist } from "zustand/middleware";
import { encodePcm } from "./audio";
import { createSong } from "./song";
import { blankTrack, type Clip, type Expression, type Note, type Pedal, type Song, type StudioMode, type Track, type TrackKind, type WaveView } from "./types";
import { applyDensity, clamp, interpretPrompt, quantizeBeat, scalePcs, sectionAt, stepScale, uid, vocalTrack } from "./theory";

export type UI = {
  mode: StudioMode;
  trackId: string;
  noteId: string | null;
  palette: boolean;
  clipId: string | null;
  selA: number;
  selB: number;
  cursor: number;
  waveView: WaveView;
  recordArm: boolean;
  octave: number;
  status: string;
  px: number;
};

type Melos = {
  song: Song;
  ui: UI;
  history: Song[];
  future: Song[];
  checkpoint: () => void;
  undo: () => void;
  redo: () => void;
  setStatus: (status: string) => void;
  setMode: (mode: StudioMode) => void;
  setPalette: (open: boolean) => void;
  patchSong: (partial: Partial<Song>, commit?: boolean) => void;
  selectTrack: (id: string) => void;
  selectNote: (id: string | null) => void;
  updateTrack: (id: string, recipe: (track: Track) => Track, commit?: boolean) => void;
  addTrack: (kind: TrackKind) => void;
  removeTrack: (id: string) => void;
  addNote: (trackId: string, note: Omit<Note, "id">) => void;
  updateNote: (trackId: string, noteId: string, partial: Partial<Note>, commit?: boolean) => void;
  deleteNote: (trackId: string, noteId: string) => void;
  quantize: (grid: number) => void;
  humanize: () => void;
  tileDrums: () => void;
  toggleDrumStep: (pitch: number, step: number) => void;
  layLyrics: (text: string) => void;
  composeLine: (text: string) => void;
  addAuto: (beat: number, value: number) => void;
  clearAuto: () => void;
  applyPrompt: (text: string) => void;
  addPedal: (pedal: Omit<Pedal, "id" | "status" | "enabled">) => void;
  setPedal: (id: string, partial: Partial<Pedal>) => void;
  selectClip: (id: string) => void;
  setSelection: (a: number, b: number) => void;
  setWaveView: (view: WaveView) => void;
  setRecordArm: (armed: boolean) => void;
  setOctave: (octave: number) => void;
  writeClip: (id: string, pcm: string, rate: number) => void;
  addClip: (name: string, pcm: string, rate: number, place: boolean) => string;
  captureRecording: (samples: Float32Array, rate: number) => void;
  addMarker: (text: string) => void;
  resetSong: () => void;
};

const seed = createSong();

const initialUI: UI = {
  mode: "song",
  trackId: seed.tracks[0]?.id ?? "tr-vocal",
  noteId: null,
  palette: false,
  clipId: seed.clips[0]?.id ?? null,
  selA: 0,
  selB: 4000,
  cursor: 0,
  waveView: "wave",
  recordArm: false,
  octave: 4,
  status: "Lamp Room is loaded. Space plays.",
  px: 52,
};

function patchExpr(base: Expression, partial: Partial<Expression>): Expression {
  const next = { ...base };
  (Object.keys(partial) as (keyof Expression)[]).forEach((key) => {
    const value = partial[key];
    if (typeof value !== "number") return;
    if (key === "formant") next[key] = clamp(base[key] + value, -6, 6);
    else next[key] = clamp(base[key] + value, 0, 1);
  });
  return next;
}

export const useMelos = create<Melos>()(
  persist(
    (set, get) => ({
      song: seed,
      ui: initialUI,
      history: [],
      future: [],
      checkpoint: () => {
        const current = get().song;
        set((s) => ({ history: [...s.history, current].slice(-24), future: [] }));
      },
      undo: () => {
        const s = get();
        const prev = s.history[s.history.length - 1];
        if (!prev) return;
        set({
          history: s.history.slice(0, -1),
          future: [s.song, ...s.future].slice(0, 24),
          song: prev,
          ui: {
            ...s.ui,
            trackId: prev.tracks.some((t) => t.id === s.ui.trackId) ? s.ui.trackId : (prev.tracks[0]?.id ?? s.ui.trackId),
            noteId: null,
            status: "Undone",
          },
        });
      },
      redo: () => {
        const s = get();
        const next = s.future[0];
        if (!next) return;
        set({
          future: s.future.slice(1),
          history: [...s.history, s.song].slice(-24),
          song: next,
          ui: { ...s.ui, status: "Redone" },
        });
      },
      setStatus: (status) => set((s) => ({ ui: { ...s.ui, status } })),
      setMode: (mode) => set((s) => ({ ui: { ...s.ui, mode } })),
      setPalette: (palette) => set((s) => ({ ui: { ...s.ui, palette } })),
      patchSong: (partial, commit) => {
        if (commit) get().checkpoint();
        set((s) => ({ song: { ...s.song, ...partial } }));
      },
      selectTrack: (trackId) => set((s) => ({ ui: { ...s.ui, trackId, noteId: null } })),
      selectNote: (noteId) => set((s) => ({ ui: { ...s.ui, noteId } })),
      updateTrack: (id, recipe, commit) => {
        if (commit) get().checkpoint();
        set((s) => ({
          song: { ...s.song, tracks: s.song.tracks.map((t) => (t.id === id ? recipe(t) : t)) },
        }));
      },
      addTrack: (kind) => {
        get().checkpoint();
        const id = uid("tr");
        const name =
          kind === "vocal" ? "Voice" : kind === "drums" ? "Kit" : kind === "bass" ? "Bass" : kind === "audio" ? "Tape" : kind === "pad" ? "Pad" : "Line";
        const track = blankTrack({ id, name, kind });
        set((s) => ({
          song: { ...s.song, tracks: [...s.song.tracks, track] },
          ui: { ...s.ui, trackId: id, status: `${name} added` },
        }));
      },
      removeTrack: (id) => {
        const tracks = get().song.tracks;
        if (tracks.length < 2) return;
        get().checkpoint();
        const next = tracks.filter((t) => t.id !== id);
        set((s) => ({
          song: { ...s.song, tracks: next },
          ui: { ...s.ui, trackId: s.ui.trackId === id ? (next[0]?.id ?? s.ui.trackId) : s.ui.trackId },
        }));
      },
      addNote: (trackId, note) => {
        get().checkpoint();
        const full: Note = { ...note, id: uid("n") };
        set((s) => ({
          song: {
            ...s.song,
            tracks: s.song.tracks.map((t) => (t.id === trackId ? { ...t, notes: [...t.notes, full] } : t)),
          },
          ui: { ...s.ui, noteId: full.id, trackId },
        }));
      },
      updateNote: (trackId, noteId, partial, commit) => {
        if (commit) get().checkpoint();
        set((s) => ({
          song: {
            ...s.song,
            tracks: s.song.tracks.map((t) =>
              t.id === trackId ? { ...t, notes: t.notes.map((n) => (n.id === noteId ? { ...n, ...partial } : n)) } : t,
            ),
          },
        }));
      },
      deleteNote: (trackId, noteId) => {
        get().checkpoint();
        set((s) => ({
          song: {
            ...s.song,
            tracks: s.song.tracks.map((t) => (t.id === trackId ? { ...t, notes: t.notes.filter((n) => n.id !== noteId) } : t)),
          },
          ui: { ...s.ui, noteId: s.ui.noteId === noteId ? null : s.ui.noteId },
        }));
      },
      quantize: (grid) => {
        const id = get().ui.trackId;
        get().checkpoint();
        get().updateTrack(id, (t) => ({
          ...t,
          notes: t.notes.map((n) => ({ ...n, start: quantizeBeat(n.start, grid) })),
        }));
        get().setStatus(`Quantized to 1/${Math.round(1 / grid)}`);
      },
      humanize: () => {
        const id = get().ui.trackId;
        get().checkpoint();
        get().updateTrack(id, (t) => ({
          ...t,
          notes: t.notes.map((n) => ({
            ...n,
            start: Math.max(0, n.start + (Math.random() - 0.5) * 0.06),
            velocity: clamp(n.velocity + Math.round((Math.random() - 0.5) * 18), 1, 127),
          })),
        }));
        get().setStatus("Humanized timing and velocity");
      },
      tileDrums: () => {
        const song = get().song;
        const track = song.tracks.find((t) => t.id === get().ui.trackId);
        if (!track) return;
        const bar = track.notes.filter((n) => n.start < song.numerator);
        if (bar.length === 0) return;
        get().checkpoint();
        const bars = Math.ceil(song.lengthBeats / song.numerator);
        const notes: Note[] = [];
        for (let i = 0; i < bars; i++) {
          for (const n of bar) {
            notes.push({ ...n, id: uid("n"), start: n.start + i * song.numerator });
          }
        }
        get().updateTrack(track.id, (t) => ({ ...t, notes }));
        get().setStatus("Pattern tiled across the song");
      },
      toggleDrumStep: (pitch, step) => {
        const song = get().song;
        const track = song.tracks.find((t) => t.id === get().ui.trackId);
        if (!track) return;
        const start = step * 0.25;
        const hit = track.notes.find((n) => n.pitch === pitch && Math.abs(n.start - start) < 0.08);
        if (hit) get().deleteNote(track.id, hit.id);
        else get().addNote(track.id, { pitch, start, duration: 0.2, velocity: pitch === 42 ? 70 : 110, lyric: "" });
      },
      layLyrics: (text) => {
        const words = text.split(/\s+/).filter(Boolean);
        if (words.length === 0) return;
        const id = get().ui.trackId;
        get().checkpoint();
        get().updateTrack(id, (t) => {
          const ordered = [...t.notes].sort((a, b) => a.start - b.start);
          const map = new Map(ordered.map((n, i) => [n.id, words[i] ?? "—"]));
          return { ...t, notes: t.notes.map((n) => ({ ...n, lyric: map.get(n.id) ?? n.lyric })) };
        });
        get().setStatus("Lyrics laid across notes");
      },
      composeLine: (text) => {
        const s = get();
        const track = s.song.tracks.find((t) => t.id === s.ui.trackId);
        if (!track) return;
        const words = text.split(/\s+/).filter(Boolean);
        if (words.length === 0) return;
        const section = sectionAt(s.song, 0) ?? s.song.sections[0];
        const start = section?.start ?? 0;
        const pcs = scalePcs(s.song.tonic, s.song.mode);
        const contour = [0, 2, 4, 3, 5, 4, 2, 0, 1, 3, 2, 0];
        get().checkpoint();
        const fresh: Note[] = words.map((lyric, i) => {
          const degree = contour[i % contour.length] ?? 0;
          const pc = pcs[degree % pcs.length] ?? 0;
          const oct = 3 + Math.floor(degree / pcs.length);
          return {
            id: uid("n"),
            pitch: (oct + 1) * 12 + pc,
            start: start + i * 0.5,
            duration: 0.5,
            velocity: 100,
            lyric,
          };
        });
        const end = start + words.length * 0.5;
        get().updateTrack(track.id, (t) => ({
          ...t,
          notes: [...t.notes.filter((n) => n.start < start || n.start >= end), ...fresh],
        }));
        get().setStatus("Phrase written in key");
      },
      addAuto: (beat, value) => {
        const id = get().ui.trackId;
        get().updateTrack(id, (t) => ({
          ...t,
          automation: [...t.automation.filter((p) => Math.abs(p.beat - beat) > 0.2), { id: uid("a"), beat, value }],
        }));
      },
      clearAuto: () => {
        get().checkpoint();
        get().updateTrack(get().ui.trackId, (t) => ({ ...t, automation: [] }));
      },
      applyPrompt: (text) => {
        const s = get();
        const track = vocalTrack(s.song);
        if (!track) return;
        const read = interpretPrompt(text);
        const beat = s.ui.cursor;
        const section = sectionAt(s.song, beat) ?? s.song.sections[0];
        get().checkpoint();
        let notes = track.notes.map((n) => {
          if (!section) return n;
          const end = section.start + section.bars * s.song.numerator;
          if (n.start < section.start || n.start >= end || read.semitones === 0) return n;
          const pcs = scalePcs(s.song.tonic, s.song.mode);
          const dir = read.semitones > 0 ? 1 : -1;
          let pitch = n.pitch;
          for (let i = 0; i < Math.abs(read.semitones); i++) pitch = stepScale(pitch, dir, pcs);
          return { ...n, pitch };
        });
        if (section) notes = applyDensity(notes, section, s.song.numerator, read.density);
        get().updateTrack(track.id, (t) => ({ ...t, notes, expression: patchExpr(t.expression, read.patch) }));
        set((st) => ({
          song: {
            ...st.song,
            prompts: [{ id: uid("pr"), text, effect: read.effect }, ...st.song.prompts].slice(0, 12),
          },
          ui: { ...st.ui, status: `Crowd · ${read.effect}` },
        }));
      },
      addPedal: (pedal) => {
        const full: Pedal = { ...pedal, id: uid("ped"), status: "pending", enabled: true };
        set((s) => ({ song: { ...s.song, pedals: [full, ...s.song.pedals] }, ui: { ...s.ui, status: `${full.name} waiting` } }));
      },
      setPedal: (id, partial) => {
        set((s) => ({
          song: { ...s.song, pedals: s.song.pedals.map((p) => (p.id === id ? { ...p, ...partial } : p)) },
        }));
      },
      selectClip: (clipId) => set((s) => ({ ui: { ...s.ui, clipId, selA: 0, selB: 2000 } })),
      setSelection: (selA, selB) => set((s) => ({ ui: { ...s.ui, selA, selB } })),
      setWaveView: (waveView) => set((s) => ({ ui: { ...s.ui, waveView } })),
      setRecordArm: (recordArm) => set((s) => ({ ui: { ...s.ui, recordArm, status: recordArm ? "Record armed — play keys" : s.ui.status } })),
      setOctave: (octave) => set((s) => ({ ui: { ...s.ui, octave: clamp(octave, 1, 7) } })),
      writeClip: (id, pcm, sampleRate) => {
        set((s) => ({
          song: { ...s.song, clips: s.song.clips.map((c) => (c.id === id ? { ...c, pcm, sampleRate } : c)) },
        }));
      },
      addClip: (name, pcm, sampleRate, place) => {
        const id = uid("clip");
        const clip: Clip = { id, name, pcm, sampleRate };
        set((s) => {
          let tracks = s.song.tracks;
          if (place) {
            let audioId = tracks.find((t) => t.kind === "audio")?.id;
            if (!audioId) {
              const created = blankTrack({ id: uid("tr"), name: "Tape", kind: "audio" });
              audioId = created.id;
              tracks = [...tracks, created];
            }
            const region = {
              id: uid("rg"),
              clipId: id,
              start: 0,
              duration: 4,
              offset: 0,
              gain: 0.7,
              fadeIn: 0.05,
              fadeOut: 0.2,
            };
            tracks = tracks.map((t) =>
              t.id === audioId ? { ...t, regions: [...t.regions, region], sampleId: t.sampleId ?? id } : t,
            );
          }
          return {
            song: { ...s.song, clips: [...s.song.clips, clip], tracks },
            ui: { ...s.ui, clipId: id, mode: "wave", status: `${name} created` },
          };
        });
        return id;
      },
      captureRecording: (samples, rate) => {
        const pcm = encodePcm(samples);
        get().addClip("Mic take", pcm, rate, true);
        get().setStatus("Mic take landed on Tape");
      },
      addMarker: (text) => {
        const clipId = get().ui.clipId;
        if (!clipId || !text.trim()) return;
        set((s) => ({
          song: {
            ...s.song,
            markers: [...s.song.markers, { id: uid("mk"), clipId, sample: s.ui.cursor, text: text.trim() }],
          },
        }));
      },
      resetSong: () => {
        const fresh = createSong();
        set({
          song: fresh,
          history: [],
          future: [],
          ui: { ...initialUI, status: "Lamp Room reset" },
        });
      },
    }),
    {
      name: "melos-studio-v1",
      skipHydration: true,
      partialize: (s) => ({ song: s.song }),
    },
  ),
);
