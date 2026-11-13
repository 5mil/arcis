import { useEffect, useRef, useState, type MouseEvent as ReactMouseEvent } from "react";
import { audition, seek, subscribe } from "@/lib/melos/engine";
import { useMelos } from "@/lib/melos/store";
import { clamp, pitchName, quantizeBeat } from "@/lib/melos/theory";
import type { Track } from "@/lib/melos/types";
import { Slider } from "./Studio";

const ROW = 20;
const DRUMS = [
  { pitch: 42, name: "Hat" },
  { pitch: 45, name: "Tom" },
  { pitch: 38, name: "Snare" },
  { pitch: 36, name: "Kick" },
];

function rowsFor(track: Track) {
  if (track.kind === "drums") return DRUMS;
  const list: { pitch: number; name: string }[] = [];
  for (let pitch = 81; pitch >= 48; pitch--) list.push({ pitch, name: pitchName(pitch) });
  return list;
}

export function SongView() {
  const song = useMelos((s) => s.song);
  const ui = useMelos((s) => s.ui);
  const track = song.tracks.find((t) => t.id === ui.trackId) ?? song.tracks[0];
  const selectTrack = useMelos((s) => s.selectTrack);
  const addTrack = useMelos((s) => s.addTrack);
  const head = useRef<HTMLDivElement>(null);
  const head2 = useRef<HTMLDivElement>(null);
  const [lyrics, setLyrics] = useState("hold the lamp in the room");

  useEffect(() => {
    return subscribe((beat) => {
      const x = `${beat * ui.px}px`;
      if (head.current) head.current.style.transform = `translateX(${x})`;
      if (head2.current) head2.current.style.transform = `translateX(${x})`;
    });
  }, [ui.px]);

  if (!track) return null;
  const rows = rowsFor(track);
  const width = song.lengthBeats * ui.px;
  const selected = track.notes.find((n) => n.id === ui.noteId) ?? null;

  return (
    <div className="song">
      <aside className="track-col">
        {song.tracks.map((t) => (
          <button key={t.id} className="track-btn" aria-selected={t.id === track.id} onClick={() => selectTrack(t.id)}>
            <strong>{t.name}</strong>
            <div className="mist">{t.kind} · {t.notes.length || t.regions.length}</div>
          </button>
        ))}
        <div className="tiny-row">
          <button className="btn" onClick={() => addTrack("vocal")}>+ Voice</button>
          <button className="btn" onClick={() => addTrack("audio")}>+ Tape</button>
        </div>
        <div className="tiny-row">
          <button className="btn" onClick={() => useMelos.getState().removeTrack(track.id)}>Remove</button>
          <button className={`btn ${track.mute ? "btn-on" : ""}`} onClick={() => useMelos.getState().updateTrack(track.id, (t) => ({ ...t, mute: !t.mute }))}>M</button>
          <button className={`btn ${track.solo ? "btn-on" : ""}`} onClick={() => useMelos.getState().updateTrack(track.id, (t) => ({ ...t, solo: !t.solo }))}>S</button>
        </div>
      </aside>
      <section className="stage">
        <div className="arrange" onClick={(e) => seekFrom(e, ui.px, song.lengthBeats)}>
          <div className="ruler" style={{ width }}>
            {Array.from({ length: Math.ceil(song.lengthBeats / song.numerator) + 1 }, (_, i) => (
              <div key={i} className="bar-mark" style={{ left: i * song.numerator * ui.px }}>{i + 1}</div>
            ))}
            {song.sections.map((s) => (
              <button
                key={s.id}
                className="section-chip"
                style={{ left: s.start * ui.px, width: s.bars * song.numerator * ui.px }}
                onClick={(e) => {
                  e.stopPropagation();
                  useMelos.getState().patchSong({ loopStart: s.start, loopEnd: s.start + s.bars * song.numerator, loopOn: true });
                  void seek(s.start);
                }}
              >
                {s.name}
              </button>
            ))}
            {song.tracks.flatMap((t) => t.regions).map((r) => (
              <div key={r.id} className="region" style={{ left: r.start * ui.px, width: Math.max(24, r.duration * ui.px) }}>
                {song.clips.find((c) => c.id === r.clipId)?.name ?? "Audio"}
              </div>
            ))}
            <div ref={head} className="playhead" />
          </div>
        </div>
        <div className="roll-scroll">
          <Roll track={track} rows={rows} width={width} px={ui.px} />
        </div>
        <div className="lane" style={{ width: "100%", position: "relative" }}>
          <div style={{ position: "relative", width, height: "100%" }} onClick={(e) => {
            const bounds = e.currentTarget.getBoundingClientRect();
            const beat = clamp((e.clientX - bounds.left) / ui.px, 0, song.lengthBeats);
            const value = clamp(1 - (e.clientY - bounds.top) / bounds.height, 0, 1);
            useMelos.getState().addAuto(beat, value);
          }}>
            {track.automation.map((p) => (
              <button key={p.id} className="auto-point" style={{ left: p.beat * ui.px, top: `${(1 - p.value) * 70}%` }} aria-label="Automation point" />
            ))}
            <div ref={head2} className="playhead" />
          </div>
        </div>
        <div className="lyric-bar">
          <input className="field grow" aria-label="Lyric line" value={lyrics} onChange={(e) => setLyrics(e.target.value)} />
          <button className="btn" onClick={() => useMelos.getState().layLyrics(lyrics)}>Lay lyrics</button>
          <button className="btn btn-primary" onClick={() => useMelos.getState().composeLine(lyrics)}>Write phrase</button>
          <button className="btn" onClick={() => useMelos.getState().quantize(0.25)}>Quantize</button>
          <button className="btn" onClick={() => useMelos.getState().humanize()}>Humanize</button>
          {track.kind === "drums" && <button className="btn" onClick={() => useMelos.getState().tileDrums()}>Tile bar</button>}
          <button className="btn" onClick={() => useMelos.getState().clearAuto()}>Clear automation</button>
        </div>
        {track.kind === "drums" && (
          <div className="steps">
            {DRUMS.map((d) => (
              <div key={d.pitch} className="row">
                <span style={{ width: 52 }}>{d.name}</span>
                {Array.from({ length: 16 }, (_, step) => {
                  const on = track.notes.some((n) => n.pitch === d.pitch && Math.abs(n.start - step * 0.25) < 0.08);
                  return (
                    <button key={step} className={`icon-btn ${on ? "btn-on" : ""}`} aria-label={`${d.name} step ${step + 1}`} aria-pressed={on} onClick={() => useMelos.getState().toggleDrumStep(d.pitch, step)} />
                  );
                })}
              </div>
            ))}
          </div>
        )}
        {selected && (
          <div className="inspector">
            <div className="row">
              <strong>{pitchName(selected.pitch)}</strong>
              <input className="field" aria-label="Syllable" value={selected.lyric} onChange={(e) => useMelos.getState().updateNote(track.id, selected.id, { lyric: e.target.value })} />
              <button className="btn" onClick={() => useMelos.getState().deleteNote(track.id, selected.id)}>Delete note</button>
            </div>
            <Slider label="Length" min={0.25} max={4} step={0.25} value={selected.duration} onChange={(duration) => useMelos.getState().updateNote(track.id, selected.id, { duration })} />
            <Slider label="Velocity" min={1} max={127} step={1} value={selected.velocity} onChange={(velocity) => useMelos.getState().updateNote(track.id, selected.id, { velocity })} />
          </div>
        )}
      </section>
    </div>
  );
}

function Roll({ track, rows, width, px }: { track: Track; rows: { pitch: number; name: string }[]; width: number; px: number }) {
  const drag = useRef<{ id: string; x: number; y: number; start: number; pitch: number; moved: boolean } | null>(null);
  const moved = useRef(false);
  const [ghost, setGhost] = useState<{ id: string; start: number; pitch: number } | null>(null);
  const gridRef = useRef<HTMLDivElement>(null);
  const noteId = useMelos((s) => s.ui.noteId);

  const pitchAt = (index: number) => rows[clamp(index, 0, rows.length - 1)]?.pitch ?? 60;

  return (
    <div className="roll" style={{ width: width + 52, ["--beat" as string]: `${px}px`, ["--row" as string]: `${ROW}px` }}>
      <div className="keys">
        {rows.map((row) => (
          <button key={row.pitch} className={`key ${[1, 3, 6, 8, 10].includes(row.pitch % 12) ? "shade" : ""}`} style={{ height: ROW }} onClick={() => void audition(row.pitch)}>
            {row.name}
          </button>
        ))}
      </div>
      <div
        ref={gridRef}
        className="grid"
        style={{ width, height: rows.length * ROW }}
        onPointerDown={(e) => {
          const local = point(e, gridRef.current);
          if (!local) return;
          const start = local.x / px;
          const pitch = pitchAt(Math.floor(local.y / ROW));
          const hit = [...track.notes].reverse().find((n) => n.pitch === pitch && start >= n.start && start <= n.start + n.duration);
          if (!hit) return;
          useMelos.getState().selectNote(hit.id);
          drag.current = { id: hit.id, x: e.clientX, y: e.clientY, start: hit.start, pitch: hit.pitch, moved: false };
          e.currentTarget.setPointerCapture(e.pointerId);
        }}
        onPointerMove={(e) => {
          if (!drag.current) return;
          const dx = e.clientX - drag.current.x;
          const dy = e.clientY - drag.current.y;
          if (Math.abs(dx) + Math.abs(dy) < 4) return;
          drag.current.moved = true;
          const start = quantizeBeat(drag.current.start + dx / px, 0.25);
          const origin = rows.findIndex((r) => r.pitch === drag.current?.pitch);
          const pitch = pitchAt(origin + Math.round(dy / ROW));
          setGhost({ id: drag.current.id, start, pitch });
        }}
        onPointerUp={() => {
          moved.current = drag.current?.moved ?? false;
          if (drag.current?.moved && ghost) {
            useMelos.getState().updateNote(track.id, ghost.id, { start: Math.max(0, ghost.start), pitch: ghost.pitch }, true);
          }
          drag.current = null;
          setGhost(null);
        }}
        onClick={(e) => {
          if (moved.current) {
            moved.current = false;
            return;
          }
          const local = point(e, gridRef.current);
          if (!local) return;
          const start = quantizeBeat(local.x / px, 0.25);
          const pitch = pitchAt(Math.floor(local.y / ROW));
          const hit = track.notes.some((n) => n.pitch === pitch && start >= n.start && start < n.start + n.duration);
          if (hit) return;
          useMelos.getState().addNote(track.id, { pitch, start, duration: track.kind === "drums" ? 0.25 : 1, velocity: 100, lyric: track.voice ? "la" : "" });
        }}
      >
        {track.notes.map((note) => {
          const shown = ghost?.id === note.id ? { ...note, ...ghost } : note;
          const index = rows.findIndex((r) => r.pitch === shown.pitch);
          if (index < 0) return null;
          return (
            <button
              key={note.id}
              className={`note note-${track.kind}`}
              aria-selected={note.id === noteId}
              style={{ top: index * ROW + 1, left: shown.start * px, width: Math.max(8, shown.duration * px - 2), height: ROW - 2 }}
            >
              {shown.duration * px > 36 ? shown.lyric || pitchName(shown.pitch) : ""}
            </button>
          );
        })}
      </div>
    </div>
  );
}

function point(e: { clientX: number; clientY: number }, el: HTMLDivElement | null) {
  if (!el) return null;
  const rect = el.getBoundingClientRect();
  return { x: e.clientX - rect.left, y: e.clientY - rect.top };
}

function seekFrom(e: ReactMouseEvent<HTMLDivElement>, px: number, length: number) {
  const rect = e.currentTarget.getBoundingClientRect();
  const beat = clamp((e.clientX - rect.left + e.currentTarget.scrollLeft) / px, 0, length);
  void seek(beat);
}
