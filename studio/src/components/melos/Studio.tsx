import { useEffect, useMemo, useRef, useState } from "react";
import { Circle, Pause, Play, RotateCcw, Search, Square } from "lucide-react";
import { startArcisBridge, useArcis } from "@/lib/engine";
import { ensureCache, resetCache } from "@/lib/melos/audio";
import { getCommands } from "@/lib/melos/commands";
import { audition, cursorBeat, isPlaying, stop, subscribe, toggle, wireEngine } from "@/lib/melos/engine";
import { useMelos } from "@/lib/melos/store";
import { formatClock, KEY_MAP, quantizeBeat } from "@/lib/melos/theory";
import { NOTE_NAMES } from "@/lib/melos/theory";
import { LiveView } from "./LiveView";
import { MixView } from "./MixView";
import { RackView } from "./RackView";
import { SongView } from "./SongView";
import { WaveBench } from "./WaveView";

const MODES = [
  ["song", "Song"],
  ["rack", "Rack"],
  ["mix", "Mix"],
  ["wave", "Wave"],
  ["live", "Live"],
] as const;

export function Studio() {
  const song = useMelos((s) => s.song);
  const ui = useMelos((s) => s.ui);
  const patchSong = useMelos((s) => s.patchSong);
  const setMode = useMelos((s) => s.setMode);
  const setPalette = useMelos((s) => s.setPalette);
  const undo = useMelos((s) => s.undo);
  const redo = useMelos((s) => s.redo);
  const clock = useRef<HTMLSpanElement>(null);
  const playRef = useRef<HTMLButtonElement>(null);

  const engineLink = useArcis((s) => s.link);
  const engineDetail = useArcis((s) => s.detail);

  useEffect(() => {
    const stopBridge = startArcisBridge();
    wireEngine();
    ensureCache(useMelos.getState().song.clips);
    const finish = useMelos.persist.onFinishHydration((state) => {
      resetCache();
      ensureCache(state.song.clips);
      const trackOk = state.song.tracks.some((t) => t.id === useMelos.getState().ui.trackId);
      if (!trackOk && state.song.tracks[0]) {
        useMelos.getState().selectTrack(state.song.tracks[0].id);
      }
    });
    void useMelos.persist.rehydrate();
    const unsub = subscribe((beat, playing) => {
      if (clock.current) clock.current.textContent = formatClock(beat, useMelos.getState().song.numerator);
      playRef.current?.setAttribute("aria-pressed", playing ? "true" : "false");
    });
    return () => {
      unsub();
      finish();
      stopBridge();
    };
  }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const target = e.target as HTMLElement | null;
      const typing = target && (target.tagName === "INPUT" || target.tagName === "TEXTAREA" || target.tagName === "SELECT");
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setPalette(!useMelos.getState().ui.palette);
        return;
      }
      if (typing) return;
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "z") {
        e.preventDefault();
        if (e.shiftKey) redo();
        else undo();
        return;
      }
      if (e.key === " ") {
        e.preventDefault();
        void toggle();
        return;
      }
      if (e.key === "z" && !e.metaKey) useMelos.getState().setOctave(useMelos.getState().ui.octave - 1);
      if (e.key === "x" && !e.metaKey) useMelos.getState().setOctave(useMelos.getState().ui.octave + 1);
      const semi = KEY_MAP[e.key.toLowerCase()];
      if (semi === undefined || e.repeat) return;
      const state = useMelos.getState();
      const pitch = (state.ui.octave + 1) * 12 + (semi % 12);
      void audition(pitch);
      if (!state.ui.recordArm || !isPlaying()) return;
      const start = quantizeBeat(cursorBeat(), 0.25);
      state.addNote(state.ui.trackId, { pitch, start, duration: 0.5, velocity: 104, lyric: "la" });
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [redo, setPalette, undo]);

  return (
    <div className="studio">
      <header className="topbar">
        <div className="brand">
          <strong>Melos</strong>
          <span>Studio</span>
        </div>
        <input
          className="title-input"
          aria-label="Song title"
          value={song.title}
          onChange={(e) => patchSong({ title: e.target.value })}
        />
        <div className="modes" role="tablist" aria-label="Studio">
          {MODES.map(([id, label]) => (
            <button key={id} className="mode" role="tab" aria-selected={ui.mode === id} onClick={() => setMode(id)}>
              {label}
            </button>
          ))}
        </div>
        <button className="icon-btn" aria-label="Commands" onClick={() => setPalette(true)}>
          <Search size={18} />
        </button>
      </header>
      <div className="transport">
        <button ref={playRef} className="btn btn-primary btn-play" aria-label="Play" aria-pressed="false" onClick={() => void toggle()}>
          <Play size={16} />
        </button>
        <button className="icon-btn" aria-label="Pause" onClick={() => void toggle()}>
          <Pause size={16} />
        </button>
        <button className="icon-btn" aria-label="Stop" onClick={() => stop()}>
          <Square size={14} />
        </button>
        <button className={`icon-btn ${ui.recordArm ? "btn-on" : ""}`} aria-label="Arm record" aria-pressed={ui.recordArm} onClick={() => useMelos.getState().setRecordArm(!ui.recordArm)}>
          <Circle size={14} />
        </button>
        <span ref={clock} className="clock">1.1.00</span>
        <label className="slider" style={{ width: 180 }}>
          <span>Tempo</span>
          <input type="range" min={40} max={180} value={song.bpm} onChange={(e) => patchSong({ bpm: Number(e.target.value) })} />
          <em>{song.bpm}</em>
        </label>
        <select className="select" aria-label="Key" value={song.tonic} onChange={(e) => patchSong({ tonic: Number(e.target.value) })}>
          {NOTE_NAMES.map((name, i) => (
            <option key={name} value={i}>{name}</option>
          ))}
        </select>
        <select className="select" aria-label="Mode" value={song.mode} onChange={(e) => patchSong({ mode: e.target.value as "major" | "minor" })}>
          <option value="minor">Minor</option>
          <option value="major">Major</option>
        </select>
        <select className="select" aria-label="Meter" value={song.numerator} onChange={(e) => patchSong({ numerator: Number(e.target.value) })}>
          <option value={4}>4/4</option>
          <option value={3}>3/4</option>
        </select>
        <button className={`btn ${song.loopOn ? "btn-on" : ""}`} onClick={() => patchSong({ loopOn: !song.loopOn })}>Loop</button>
        <button className={`btn ${song.metronome ? "btn-on" : ""}`} onClick={() => patchSong({ metronome: !song.metronome })}>Click</button>
        <button className="icon-btn" aria-label="Undo" onClick={() => undo()}><RotateCcw size={16} /></button>
        <button className="btn" onClick={() => redo()}>Redo</button>
      </div>
      <main className="workspace">
        {ui.mode === "song" && <SongView />}
        {ui.mode === "rack" && <RackView />}
        {ui.mode === "mix" && <MixView />}
        {ui.mode === "wave" && <WaveBench />}
        {ui.mode === "live" && <LiveView />}
      </main>
      <footer className="statusbar">
        <span>{ui.status}</span>
        <span className="grow" />
        <span className={`engine-pill ${engineLink}`} title={engineDetail} role="status">
          <i aria-hidden="true" />
          Engine: {engineLink === "connected" ? "connected" : "local"}
        </span>
        <span>Oct {ui.octave}</span>
        <span>Keys A–K · Z/X octave · ⌘K commands</span>
      </footer>
      {ui.palette && <Palette />}
    </div>
  );
}

function Palette() {
  const setPalette = useMelos((s) => s.setPalette);
  const [q, setQ] = useState("");
  const commands = useMemo(() => getCommands(), []);
  const list = commands.filter((c) => `${c.label} ${c.group}`.toLowerCase().includes(q.toLowerCase()));
  return (
    <div className="palette-back" onClick={() => setPalette(false)}>
      <div className="palette" role="dialog" aria-label="Command palette" onClick={(e) => e.stopPropagation()}>
        <input className="search" autoFocus placeholder="Search the bench" value={q} onChange={(e) => setQ(e.target.value)} />
        <ul>
          {list.slice(0, 18).map((c) => (
            <li key={c.id}>
              <button
                onClick={() => {
                  setPalette(false);
                  c.run();
                }}
              >
                <span>{c.label}</span>
                <small>{c.group}</small>
              </button>
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}

export function Slider({
  label,
  value,
  min,
  max,
  step,
  onChange,
}: {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  onChange: (value: number) => void;
}) {
  return (
    <label className="slider">
      <span>{label}</span>
      <input type="range" min={min} max={max} step={step} value={value} onChange={(e) => onChange(Number(e.target.value))} />
      <em>{Number(value.toFixed(2))}</em>
    </label>
  );
}
