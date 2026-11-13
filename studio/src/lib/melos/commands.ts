import {
  commitSamples,
  downloadBlob,
  encodePcm,
  encodeWav,
  ensureCache,
  getClipboard,
  getRate,
  getSamples,
  hasRedo,
  hasUndo,
  makeNoise,
  makeSilence,
  makeTone,
  monoWav,
  opAmplify,
  opCopy,
  opCut,
  opDeclick,
  opEcho,
  opEq,
  opFade,
  opInvert,
  opNoiseReduce,
  opNormalize,
  opPaste,
  opPitchKeep,
  opResample,
  opReverse,
  opSilence,
  opTrim,
  profileRms,
  redoSamples,
  selection,
  stereoInterleave,
  undoSamples,
} from "./audio";
import { cursorBeat, renderMixdown, renderTrack, seek, stop, toggle, toggleMic } from "./engine";
import { downloadBytes, lyricsDocument, songToMidi } from "./midi";
import { useMelos } from "./store";
import { formatClock, pitchName, vocalTrack } from "./theory";
import type { TrackKind } from "./types";

export type Command = { id: string; group: string; label: string; run: () => void };

function status(text: string) {
  useMelos.getState().setStatus(text);
}

function withClip(run: (id: string, data: Float32Array, rate: number, a: number, b: number) => Float32Array | null) {
  const { song, ui } = useMelos.getState();
  ensureCache(song.clips);
  const id = ui.clipId;
  if (!id) {
    status("Select a clip in the wave bench");
    return;
  }
  const data = getSamples(id);
  if (!data || data.length === 0) {
    status("Clip is empty");
    return;
  }
  const rate = getRate(id);
  const { start, end } = selection(data.length, ui.selA, ui.selB);
  const next = run(id, data, rate, start, end);
  if (!next) return;
  commitSamples(id, next, rate, true);
  useMelos.getState().writeClip(id, encodePcm(next), rate);
  useMelos.getState().setSelection(0, Math.min(next.length, Math.max(end, 1)));
}

export function waveUndo() {
  const id = useMelos.getState().ui.clipId;
  if (!id || !hasUndo(id)) return;
  const data = undoSamples(id);
  if (!data) return;
  useMelos.getState().writeClip(id, encodePcm(data), getRate(id));
  status("Wave undo");
}

export function waveRedo() {
  const id = useMelos.getState().ui.clipId;
  if (!id || !hasRedo(id)) return;
  const data = redoSamples(id);
  if (!data) return;
  useMelos.getState().writeClip(id, encodePcm(data), getRate(id));
  status("Wave redo");
}

export function exportClip() {
  const id = useMelos.getState().ui.clipId;
  if (!id) return;
  ensureCache(useMelos.getState().song.clips);
  const data = getSamples(id);
  if (!data) return;
  const clip = useMelos.getState().song.clips.find((c) => c.id === id);
  downloadBlob(monoWav(data, getRate(id)), `${clip?.name ?? "clip"}.wav`);
  status("Clip exported");
}

export async function exportMix() {
  status("Rendering mix…");
  const buffer = await renderMixdown();
  downloadBlob(encodeWav(stereoInterleave(buffer), buffer.sampleRate, 2), `${useMelos.getState().song.title}.wav`);
  status("Mixdown downloaded");
}

export async function bounceTrack() {
  const id = useMelos.getState().ui.trackId;
  const track = useMelos.getState().song.tracks.find((t) => t.id === id);
  status(`Bouncing ${track?.name ?? "track"}…`);
  const buffer = await renderTrack(id);
  const data = buffer.getChannelData(0).slice(0);
  const pcm = encodePcm(data);
  useMelos.getState().addClip(`${track?.name ?? "Track"} bounce`, pcm, buffer.sampleRate, true);
  const clipId = useMelos.getState().ui.clipId;
  if (clipId) commitSamples(clipId, data, buffer.sampleRate, false);
  status("Bounce placed on Tape");
}

export function exportPacket() {
  const song = useMelos.getState().song;
  const midi = songToMidi(song);
  downloadBytes(midi, `${song.title}.mid`, "audio/midi");
  const lyrics = new Blob([lyricsDocument(song)], { type: "text/plain" });
  downloadBlob(lyrics, `${song.title}-lyrics.txt`);
  const vocal = vocalTrack(song);
  const json = new Blob(
    [JSON.stringify({ engine: song.vocalEngine, expression: vocal?.expression ?? null, title: song.title }, null, 2)],
    { type: "application/json" },
  );
  downloadBlob(json, `${song.title}-expression.json`);
  status("MIDI, lyrics, and expression packet saved");
}

function generate(kind: "tone" | "noise" | "silence") {
  const seconds = 2;
  const rate = 22050;
  const data = kind === "tone" ? makeTone(220, seconds, rate) : kind === "noise" ? makeNoise(seconds, rate) : makeSilence(seconds, rate);
  const id = useMelos.getState().addClip(kind === "tone" ? "Tone" : kind === "noise" ? "Noise" : "Silence", encodePcm(data), rate, kind !== "silence");
  commitSamples(id, data, rate, false);
  status(`${kind} generated`);
}

export function getCommands(): Command[] {
  const go = (mode: "song" | "rack" | "mix" | "wave" | "live") => useMelos.getState().setMode(mode);
  const add = (kind: TrackKind) => useMelos.getState().addTrack(kind);
  return [
    { id: "play", group: "Transport", label: "Play or pause", run: () => void toggle() },
    { id: "stop", group: "Transport", label: "Stop and return", run: () => stop() },
    { id: "seek", group: "Transport", label: "Seek to start of loop", run: () => void seek(useMelos.getState().song.loopStart) },
    { id: "metro", group: "Transport", label: "Toggle metronome", run: () => useMelos.getState().patchSong({ metronome: !useMelos.getState().song.metronome }) },
    { id: "loop", group: "Transport", label: "Toggle loop", run: () => useMelos.getState().patchSong({ loopOn: !useMelos.getState().song.loopOn }) },
    { id: "arm", group: "Transport", label: "Arm keyboard record", run: () => useMelos.getState().setRecordArm(!useMelos.getState().ui.recordArm) },
    { id: "mic", group: "Transport", label: "Record microphone", run: () => void toggleMic().catch(() => status("Microphone permission was blocked")) },
    { id: "song", group: "Views", label: "Song sequencer", run: () => go("song") },
    { id: "rack", group: "Views", label: "Device rack", run: () => go("rack") },
    { id: "mix", group: "Views", label: "Mixer", run: () => go("mix") },
    { id: "wave", group: "Views", label: "Wave bench", run: () => go("wave") },
    { id: "live", group: "Views", label: "Live stage", run: () => go("live") },
    { id: "undo", group: "Edit", label: "Undo arrangement", run: () => useMelos.getState().undo() },
    { id: "redo", group: "Edit", label: "Redo arrangement", run: () => useMelos.getState().redo() },
    { id: "q16", group: "Edit", label: "Quantize to 1/16", run: () => useMelos.getState().quantize(0.25) },
    { id: "q8", group: "Edit", label: "Quantize to 1/8", run: () => useMelos.getState().quantize(0.5) },
    { id: "human", group: "Edit", label: "Humanize", run: () => useMelos.getState().humanize() },
    { id: "tile", group: "Edit", label: "Tile first bar", run: () => useMelos.getState().tileDrums() },
    { id: "voice", group: "Tracks", label: "Add voice track", run: () => add("vocal") },
    { id: "bass", group: "Tracks", label: "Add bass track", run: () => add("bass") },
    { id: "drums", group: "Tracks", label: "Add drum track", run: () => add("drums") },
    { id: "pad", group: "Tracks", label: "Add pad track", run: () => add("pad") },
    { id: "audio", group: "Tracks", label: "Add tape track", run: () => add("audio") },
    { id: "tone", group: "Generate", label: "Generate tone", run: () => generate("tone") },
    { id: "noise", group: "Generate", label: "Generate noise", run: () => generate("noise") },
    { id: "silence", group: "Generate", label: "Generate silence", run: () => generate("silence") },
    { id: "norm", group: "Wave", label: "Normalize", run: () => withClip((_i, d, _r, a, b) => opNormalize(d, a, b)) },
    { id: "amp", group: "Wave", label: "Amplify +3 dB", run: () => withClip((_i, d, _r, a, b) => opAmplify(d, a, b, 10 ** (3 / 20))) },
    { id: "rev", group: "Wave", label: "Reverse", run: () => withClip((_i, d, _r, a, b) => opReverse(d, a, b)) },
    { id: "inv", group: "Wave", label: "Invert", run: () => withClip((_i, d, _r, a, b) => opInvert(d, a, b)) },
    { id: "fin", group: "Wave", label: "Fade in", run: () => withClip((_i, d, _r, a, b) => opFade(d, a, b, true)) },
    { id: "fout", group: "Wave", label: "Fade out", run: () => withClip((_i, d, _r, a, b) => opFade(d, a, b, false)) },
    { id: "sil", group: "Wave", label: "Silence selection", run: () => withClip((_i, d, _r, a, b) => opSilence(d, a, b)) },
    { id: "trim", group: "Wave", label: "Trim to selection", run: () => withClip((_i, d, _r, a, b) => opTrim(d, a, b)) },
    { id: "cut", group: "Wave", label: "Cut selection", run: () => withClip((_i, d, _r, a, b) => opCut(d, a, b)) },
    { id: "copy", group: "Wave", label: "Copy selection", run: () => { const { song, ui } = useMelos.getState(); ensureCache(song.clips); const id = ui.clipId; const data = id ? getSamples(id) : undefined; if (!data || !id) return; const { start, end } = selection(data.length, ui.selA, ui.selB); opCopy(data, start, end); status("Copied"); } },
    { id: "paste", group: "Wave", label: "Paste", run: () => { if (!getClipboard()) { status("Clipboard empty"); return; } withClip((_i, d) => opPaste(d, useMelos.getState().ui.cursor)); } },
    { id: "echo", group: "Wave", label: "Echo", run: () => withClip((_i, d, r, a, b) => opEcho(d, a, b, 0.22, r, 0.45)) },
    { id: "eq", group: "Wave", label: "Shelf EQ", run: () => withClip((_i, d, _r, a, b) => opEq(d, a, b, 3, -2)) },
    { id: "nr", group: "Wave", label: "Reduce noise", run: () => withClip((_i, d, _r, a, b) => opNoiseReduce(d, a, b, profileRms(d, a, b))) },
    { id: "click", group: "Wave", label: "Remove clicks", run: () => withClip((_i, d, _r, a, b) => opDeclick(d, a, b)) },
    { id: "pitch", group: "Wave", label: "Pitch +2 (keep length)", run: () => withClip((_i, d) => opPitchKeep(d, 2)) },
    { id: "speed", group: "Wave", label: "Change speed 90%", run: () => withClip((_i, d) => opResample(d, 0.9)) },
    { id: "wundo", group: "Wave", label: "Undo wave edit", run: () => waveUndo() },
    { id: "wredo", group: "Wave", label: "Redo wave edit", run: () => waveRedo() },
    { id: "wav", group: "Export", label: "Export clip WAV", run: () => exportClip() },
    { id: "mix", group: "Export", label: "Mix and render WAV", run: () => void exportMix() },
    { id: "bounce", group: "Export", label: "Bounce selected track", run: () => void bounceTrack() },
    { id: "packet", group: "Export", label: "Vocal packet for licensed editor", run: () => exportPacket() },
    { id: "reset", group: "Song", label: "Reset Lamp Room", run: () => useMelos.getState().resetSong() },
    {
      id: "clock",
      group: "Song",
      label: `Clock ${formatClock(cursorBeat(), useMelos.getState().song.numerator)}`,
      run: () => status(formatClock(cursorBeat(), useMelos.getState().song.numerator)),
    },
  ];
}

export function noteLabel(pitch: number) {
  return pitchName(pitch);
}
