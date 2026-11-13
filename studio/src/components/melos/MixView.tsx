import { useEffect, useState } from "react";
import { getMeter } from "@/lib/melos/engine";
import { useMelos } from "@/lib/melos/store";
import { gainLabel } from "@/lib/melos/theory";
import { Slider } from "./Studio";

export function MixView() {
  const tracks = useMelos((s) => s.song.tracks);
  const master = useMelos((s) => s.song.master);
  const [peaks, setPeaks] = useState<Record<string, number>>({});
  useEffect(() => {
    let frame = 0;
    let last = 0;
    const loop = (t: number) => {
      if (t - last > 90) {
        last = t;
        const next: Record<string, number> = { master: getMeter("master") };
        for (const track of useMelos.getState().song.tracks) next[track.id] = getMeter(track.id);
        setPeaks(next);
      }
      frame = requestAnimationFrame(loop);
    };
    frame = requestAnimationFrame(loop);
    return () => cancelAnimationFrame(frame);
  }, []);

  return (
    <div className="mix">
      <div className="strips">
        {tracks.map((track) => (
          <article key={track.id} className="strip">
            <strong>{track.name}</strong>
            <div className="meter" aria-hidden="true"><i style={{ width: `${Math.min(100, (peaks[track.id] ?? 0) * 100)}%` }} /></div>
            <Slider label="Pan" min={-1} max={1} step={0.01} value={track.pan} onChange={(pan) => useMelos.getState().updateTrack(track.id, (t) => ({ ...t, pan }))} />
            <Slider label="Low" min={-12} max={12} step={0.5} value={track.eq.lo} onChange={(lo) => useMelos.getState().updateTrack(track.id, (t) => ({ ...t, eq: { ...t.eq, lo } }))} />
            <Slider label="High" min={-12} max={12} step={0.5} value={track.eq.hi} onChange={(hi) => useMelos.getState().updateTrack(track.id, (t) => ({ ...t, eq: { ...t.eq, hi } }))} />
            <Slider label="Delay" min={0} max={1} step={0.01} value={track.delay.mix} onChange={(mix) => useMelos.getState().updateTrack(track.id, (t) => ({ ...t, delay: { ...t.delay, mix } }))} />
            <Slider label="Space" min={0} max={1} step={0.01} value={track.space} onChange={(space) => useMelos.getState().updateTrack(track.id, (t) => ({ ...t, space }))} />
            <div className="row">
              <button className={`btn ${track.mute ? "btn-on" : ""}`} onClick={() => useMelos.getState().updateTrack(track.id, (t) => ({ ...t, mute: !t.mute }))}>Mute</button>
              <button className={`btn ${track.solo ? "btn-on" : ""}`} onClick={() => useMelos.getState().updateTrack(track.id, (t) => ({ ...t, solo: !t.solo }))}>Solo</button>
            </div>
            <div className="vwrap">
              <input className="vrange" aria-label={`${track.name} fader`} type="range" min={0} max={1} step={0.01} value={track.gain} onChange={(e) => useMelos.getState().updateTrack(track.id, (t) => ({ ...t, gain: Number(e.target.value) }))} />
            </div>
            <span className="mist">{gainLabel(track.gain)}</span>
          </article>
        ))}
        <article className="strip">
          <strong>Master</strong>
          <div className="meter"><i style={{ width: `${Math.min(100, (peaks.master ?? 0) * 100)}%` }} /></div>
          <div className="vwrap">
            <input className="vrange" aria-label="Master fader" type="range" min={0} max={1} step={0.01} value={master} onChange={(e) => useMelos.getState().patchSong({ master: Number(e.target.value) })} />
          </div>
          <span className="mist">{gainLabel(master)}</span>
          <button className="btn btn-primary" onClick={() => void import("@/lib/melos/commands").then((m) => m.exportMix())}>Render</button>
        </article>
      </div>
    </div>
  );
}
