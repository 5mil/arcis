import { useEffect, useRef, useState, type PointerEvent as ReactPointerEvent } from "react";
import {
  ensureCache,
  fftMag,
  getSamples,
  hasRedo,
  hasUndo,
  onAudio,
  profileRms,
} from "@/lib/melos/audio";
import { exportClip, waveRedo, waveUndo } from "@/lib/melos/commands";
import { useMelos } from "@/lib/melos/store";

const TOOLS = [
  ["Normalize", "norm"],
  ["+3 dB", "amp"],
  ["Reverse", "rev"],
  ["Invert", "inv"],
  ["Fade in", "fin"],
  ["Fade out", "fout"],
  ["Silence", "sil"],
  ["Trim", "trim"],
  ["Cut", "cut"],
  ["Copy", "copy"],
  ["Paste", "paste"],
  ["Echo", "echo"],
  ["EQ", "eq"],
  ["Denoise", "nr"],
  ["De-click", "click"],
  ["Pitch +2", "pitch"],
  ["Speed 90", "speed"],
] as const;

export function WaveBench() {
  const song = useMelos((s) => s.song);
  const ui = useMelos((s) => s.ui);
  const canvas = useRef<HTMLCanvasElement>(null);
  const [, setRev] = useState(0);
  const clip = song.clips.find((c) => c.id === ui.clipId) ?? song.clips[0];

  useEffect(() => ensureCache(song.clips), [song.clips]);
  useEffect(() => onAudio(() => setRev((n) => n + 1)), []);

  useEffect(() => {
    const el = canvas.current;
    if (!el || !clip) return;
    ensureCache(song.clips);
    const data = getSamples(clip.id);
    if (!data) return;
    draw(el, data, ui.selA, ui.selB, ui.waveView);
  });

  const data = clip ? getSamples(clip.id) : undefined;
  const sel = data ? bounds(data.length, ui.selA, ui.selB) : { start: 0, end: 0 };
  const rms = data ? profileRms(data, sel.start, sel.end) : 0;
  let peak = 0;
  if (data) for (let i = sel.start; i < sel.end; i++) peak = Math.max(peak, Math.abs(data[i] ?? 0));

  return (
    <div className="wave">
      <aside className="wave-side">
        <div className="tiny-row">
          <button className="btn" onClick={() => run("tone")}>Tone</button>
          <button className="btn" onClick={() => run("noise")}>Noise</button>
          <button className="btn" onClick={() => run("silence")}>Silence</button>
        </div>
        {song.clips.map((c) => (
          <button key={c.id} className="clip-btn" aria-selected={c.id === clip?.id} onClick={() => useMelos.getState().selectClip(c.id)}>
            {c.name}
          </button>
        ))}
        <div className="panel stack">
          <h3>Markers</h3>
          {song.markers.filter((m) => m.clipId === clip?.id).map((m) => (
            <div key={m.id} className="mist">{m.text} · {m.sample}</div>
          ))}
          <button className="btn" onClick={() => useMelos.getState().addMarker("mark")}>Add marker</button>
          <div className="mist">Peak {peak.toFixed(2)} · RMS {rms.toFixed(3)}</div>
          <div className="mist">{clip ? `${((data?.length ?? 0) / clip.sampleRate).toFixed(2)}s` : ""}</div>
          <button className="btn" disabled={!clip || !hasUndo(clip.id)} onClick={() => waveUndo()}>Undo edit</button>
          <button className="btn" disabled={!clip || !hasRedo(clip.id)} onClick={() => waveRedo()}>Redo edit</button>
          <button className="btn btn-primary" onClick={() => exportClip()}>Export WAV</button>
        </div>
      </aside>
      <div className="wave-main">
        <div className="tools">
          <button className={`btn ${ui.waveView === "wave" ? "btn-on" : ""}`} onClick={() => useMelos.getState().setWaveView("wave")}>Wave</button>
          <button className={`btn ${ui.waveView === "spectrum" ? "btn-on" : ""}`} onClick={() => useMelos.getState().setWaveView("spectrum")}>Spectrum</button>
          {TOOLS.map(([label, id]) => (
            <button key={id} className="btn" onClick={() => run(id)}>{label}</button>
          ))}
        </div>
        <div
          className="canvas-wrap"
          onPointerDown={(e) => dragSelect(e, true)}
          onPointerMove={(e) => { if (e.buttons === 1) dragSelect(e, false); }}
        >
          <canvas ref={canvas} className="wave-canvas" />
        </div>
        <div className="statusbar">
          <span>Selection {sel.start}–{sel.end}</span>
          <span className="grow" />
          <span>Destructive edits stay on the clip. Bounce a track from the command palette to print MIDI into audio.</span>
        </div>
      </div>
    </div>
  );
}

function bounds(len: number, a: number, b: number) {
  const start = Math.max(0, Math.min(len, Math.floor(Math.min(a, b))));
  const end = Math.max(start + 1, Math.min(len, Math.floor(Math.max(a, b))));
  return { start, end };
}

function dragSelect(e: ReactPointerEvent<HTMLDivElement>, anchor: boolean) {
  const clip = useMelos.getState().song.clips.find((c) => c.id === useMelos.getState().ui.clipId);
  const data = clip ? getSamples(clip.id) : undefined;
  if (!data) return;
  const rect = e.currentTarget.getBoundingClientRect();
  const ratio = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
  const sample = Math.floor(ratio * data.length);
  const ui = useMelos.getState().ui;
  if (anchor) useMelos.getState().setSelection(sample, sample + 1);
  else useMelos.getState().setSelection(ui.selA, sample);
  useMelos.setState((s) => ({ ui: { ...s.ui, cursor: sample } }));
}

function draw(canvas: HTMLCanvasElement, data: Float32Array, selA: number, selB: number, view: "wave" | "spectrum") {
  const dpr = window.devicePixelRatio || 1;
  const w = Math.max(1, canvas.clientWidth);
  const h = Math.max(1, canvas.clientHeight);
  canvas.width = Math.floor(w * dpr);
  canvas.height = Math.floor(h * dpr);
  const g = canvas.getContext("2d");
  if (!g) return;
  g.setTransform(dpr, 0, 0, dpr, 0, 0);
  const amber = getComputedStyle(document.documentElement).getPropertyValue("--color-amber").trim();
  const ink = getComputedStyle(document.documentElement).getPropertyValue("--color-ink").trim();
  g.fillStyle = ink || "#0c0d0f";
  g.fillRect(0, 0, w, h);
  if (view === "spectrum") {
    const fft = 1024;
    const hop = 512;
    const cols = Math.min(140, Math.floor(data.length / hop));
    for (let c = 0; c < cols; c++) {
      const frame = new Float32Array(fft);
      const start = c * hop;
      for (let i = 0; i < fft; i++) {
        const win = 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / fft);
        frame[i] = (data[start + i] ?? 0) * win;
      }
      const mag = fftMag(frame);
      const step = Math.floor(mag.length / 48);
      for (let b = 0; b < 48; b++) {
        const m = mag[b * step] ?? 0;
        g.globalAlpha = 0.2 + m * 0.8;
        g.fillStyle = amber || "#e6a15c";
        const bh = h / 48;
        g.fillRect((c / cols) * w, h - (b + 1) * bh, w / cols + 1, bh + 1);
      }
    }
    g.globalAlpha = 1;
    return;
  }
  g.strokeStyle = amber || "#e6a15c";
  g.beginPath();
  const spp = data.length / w;
  for (let x = 0; x < w; x++) {
    let min = 1;
    let max = -1;
    const a = Math.floor(x * spp);
    const b = Math.min(data.length, Math.floor((x + 1) * spp));
    for (let i = a; i < b; i++) {
      const s = data[i] ?? 0;
      if (s < min) min = s;
      if (s > max) max = s;
    }
    g.moveTo(x + 0.5, ((1 - max) * 0.5) * h);
    g.lineTo(x + 0.5, ((1 - min) * 0.5) * h);
  }
  g.stroke();
  const a = (Math.min(selA, selB) / data.length) * w;
  const b = (Math.max(selA, selB) / data.length) * w;
  g.fillStyle = amber || "#e6a15c";
  g.globalAlpha = 0.18;
  g.fillRect(a, 0, Math.max(1, b - a), h);
  g.globalAlpha = 1;
}

function run(id: string) {
  void import("@/lib/melos/commands").then((mod) => {
    const cmd = mod.getCommands().find((c) => c.id === id);
    cmd?.run();
  });
}
