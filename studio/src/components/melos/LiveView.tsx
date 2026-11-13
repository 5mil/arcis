import { useEffect, useRef, useState } from "react";
import { getMeter } from "@/lib/melos/engine";
import { exportPacket } from "@/lib/melos/commands";
import { useMelos } from "@/lib/melos/store";
import type { TrackKind, VocalEngine } from "@/lib/melos/types";
import { Slider } from "./Studio";

const ENGINES: { id: VocalEngine; label: string; hint: string }[] = [
  { id: "vocaloid", label: "VOCALOID VST", hint: "Import MIDI into the VOCALOID Editor plugin you already own." },
  { id: "synthv", label: "Synthesizer V", hint: "Import MIDI, then assign syllables in Synthesizer V Studio." },
  { id: "ace", label: "ACE Studio", hint: "Drop the MIDI on a vocal track in ACE and paste the lyric list." },
  { id: "emvoice", label: "Emvoice", hint: "One syllable per note — the packet is already split that way." },
];

export function LiveView() {
  const song = useMelos((s) => s.song);
  const canvas = useRef<HTMLCanvasElement>(null);
  const [text, setText] = useState("breathier verse, lift the chorus");
  const [name, setName] = useState("Hall breath");
  const [author, setAuthor] = useState("audience");
  const vocal = song.tracks.find((t) => t.kind === "vocal");

  useEffect(() => {
    const el = canvas.current;
    if (!el) return;
    let frame = 0;
    const draw = () => {
      const g = el.getContext("2d");
      if (!g) return;
      const w = el.clientWidth;
      const h = el.clientHeight;
      const dpr = window.devicePixelRatio || 1;
      el.width = Math.floor(w * dpr);
      el.height = Math.floor(h * dpr);
      g.setTransform(dpr, 0, 0, dpr, 0, 0);
      g.clearRect(0, 0, w, h);
      const amber = getComputedStyle(document.documentElement).getPropertyValue("--color-amber").trim();
      const level = getMeter("master");
      const bars = 48;
      for (let i = 0; i < bars; i++) {
        const wobble = 0.35 + Math.abs(Math.sin(Date.now() / 280 + i * 0.35)) * 0.65;
        const bh = Math.max(4, (h * 0.55) * level * wobble);
        g.fillStyle = amber || "#e6a15c";
        g.globalAlpha = 0.35 + level * 0.6;
        g.fillRect((i / bars) * w, h * 0.62 - bh, w / bars - 3, bh);
      }
      g.globalAlpha = 1;
      frame = requestAnimationFrame(draw);
    };
    frame = requestAnimationFrame(draw);
    return () => cancelAnimationFrame(frame);
  }, []);

  return (
    <div className="live">
      <div className="stage-view">
        <canvas ref={canvas} />
        <div className="stage-copy">
          <div>
            <div className="mist">Live room</div>
            <strong>{song.title}</strong>
          </div>
          <div className="mist">{song.bpm} · {song.structureAware ? "Sections shape the voice" : "Sections off"}</div>
        </div>
      </div>
      <aside className="crowd">
        <form className="stack" onSubmit={(e) => { e.preventDefault(); if (text.trim()) useMelos.getState().applyPrompt(text.trim()); }}>
          <label className="stack">
            <span className="mist">Crowd prompt</span>
            <input className="field" value={text} onChange={(e) => setText(e.target.value)} aria-label="Crowd prompt" />
          </label>
          <button className="btn btn-primary" type="submit">Modulate</button>
        </form>
        <div className="row">
          {["breathier", "lift the chorus", "darker", "sparser", "higher"].map((p) => (
            <button key={p} className="btn" onClick={() => useMelos.getState().applyPrompt(p)}>{p}</button>
          ))}
        </div>
        {song.prompts.map((p) => (
          <div key={p.id} className="prompt">
            <small>{p.effect}</small>
            <div>{p.text}</div>
          </div>
        ))}
        {vocal && (
          <div className="panel stack">
            <h3>Voice</h3>
            <Slider label="Breath" min={0} max={1} step={0.01} value={vocal.expression.breath} onChange={(breath) => useMelos.getState().updateTrack(vocal.id, (t) => ({ ...t, expression: { ...t.expression, breath } }))} />
            <Slider label="Power" min={0} max={1} step={0.01} value={vocal.expression.power} onChange={(power) => useMelos.getState().updateTrack(vocal.id, (t) => ({ ...t, expression: { ...t.expression, power } }))} />
          </div>
        )}
        <PedalForm name={name} author={author} setName={setName} setAuthor={setAuthor} />
        <div className="stack">
          {song.pedals.map((p) => (
            <div key={p.id} className="prompt">
              <strong>{p.name}</strong>
              <div className="mist">{p.author} · {p.target} · {p.status}</div>
              <div className="row">
                <button className="btn btn-primary" onClick={() => useMelos.getState().setPedal(p.id, { status: "approved", enabled: true })}>Approve</button>
                <button className="btn" onClick={() => useMelos.getState().setPedal(p.id, { enabled: !p.enabled })}>{p.enabled ? "Bypass" : "Enable"}</button>
                <button className="btn" onClick={() => useMelos.getState().setPedal(p.id, { status: "rejected", enabled: false })}>Reject</button>
              </div>
            </div>
          ))}
        </div>
        <div className="panel stack">
          <h3>Licensed voicebanks</h3>
          <p className="mist">Melos does not include commercial voices. It plays a preview, then hands MIDI, syllables, and expression to the plugin you bought.</p>
          <div className="row">
            {ENGINES.map((engine) => (
              <button key={engine.id} className={`btn ${song.vocalEngine === engine.id ? "btn-on" : ""}`} onClick={() => useMelos.getState().patchSong({ vocalEngine: engine.id })}>
                {engine.label}
              </button>
            ))}
          </div>
          <p className="mist">{ENGINES.find((e) => e.id === song.vocalEngine)?.hint}</p>
          <button className="btn btn-primary" onClick={() => exportPacket()}>Download session packet</button>
          <label className="stack">
            <span className="mist">Kick channel</span>
            <input className="field" value={song.kickChannel} aria-label="Kick channel" placeholder="channel name" onChange={(e) => useMelos.getState().patchSong({ kickChannel: e.target.value.trim() })} />
          </label>
          {song.kickChannel && (
            <iframe className="kick" title="Kick stream" src={`https://player.kick.com/${encodeURIComponent(song.kickChannel)}`} allow="fullscreen" />
          )}
        </div>
      </aside>
    </div>
  );
}

function PedalForm({ name, author, setName, setAuthor }: { name: string; author: string; setName: (v: string) => void; setAuthor: (v: string) => void }) {
  const [target, setTarget] = useState<TrackKind | "all">("vocal");
  const [breath, setBreath] = useState(0.15);
  const [reverb, setReverb] = useState(0.2);
  return (
    <form className="panel stack" onSubmit={(e) => {
      e.preventDefault();
      useMelos.getState().addPedal({ name, author, target, breath, tension: 0, pitch: 0, reverb, formant: 0 });
    }}>
      <h3>Build a pedal</h3>
      <input className="field" aria-label="Pedal name" value={name} onChange={(e) => setName(e.target.value)} />
      <input className="field" aria-label="Author" value={author} onChange={(e) => setAuthor(e.target.value)} />
      <select className="select" aria-label="Pedal target" value={target} onChange={(e) => setTarget(e.target.value as TrackKind | "all")}>
        <option value="all">All</option>
        <option value="vocal">Voice</option>
        <option value="harmony">Harmony</option>
        <option value="bass">Bass</option>
        <option value="drums">Drums</option>
        <option value="pad">Pad</option>
      </select>
      <Slider label="Breath" min={-0.4} max={0.4} step={0.01} value={breath} onChange={setBreath} />
      <Slider label="Space" min={0} max={0.6} step={0.01} value={reverb} onChange={setReverb} />
      <button className="btn" type="submit">Submit pedal</button>
    </form>
  );
}
