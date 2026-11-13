import type { ReactNode } from "react";
import { useMelos } from "@/lib/melos/store";
import type { Bypass, Instrument, ModDest, ModSource, Track } from "@/lib/melos/types";
import { Slider } from "./Studio";
import { TEST_BANKS, voicebank } from "@/lib/melos/voicebanks";

const WAVES = ["Triangle", "Saw", "Square"];

export function RackView() {
  const song = useMelos((s) => s.song);
  const trackId = useMelos((s) => s.ui.trackId);
  const track = song.tracks.find((t) => t.id === trackId) ?? song.tracks[0];
  const update = useMelos((s) => s.updateTrack);
  if (!track) return null;
  const set = (recipe: (t: Track) => Track) => update(track.id, recipe);

  return (
    <div className="rack">
      <aside className="track-col">
        {song.tracks.map((t) => (
          <button key={t.id} className="track-btn" aria-selected={t.id === track.id} onClick={() => useMelos.getState().selectTrack(t.id)}>
            {t.name}
          </button>
        ))}
      </aside>
      <div className="devices">
        <article className="device">
          <h3>Instrument</h3>
          <div className="row">
            {(["filament", "pulse", "fold"] as Instrument[]).map((id) => (
              <button key={id} className={`btn ${track.instrument === id ? "btn-on" : ""}`} onClick={() => set((t) => ({ ...t, instrument: id }))}>
                {id}
              </button>
            ))}
            <button className={`btn ${track.voice ? "btn-on" : ""}`} onClick={() => set((t) => ({ ...t, voice: !t.voice }))}>Voice model</button>
          </div>
          <Slider label="Wave" min={0} max={2} step={1} value={track.osc.wave} onChange={(wave) => set((t) => ({ ...t, osc: { ...t.osc, wave } }))} />
          <div className="mist">{WAVES[track.osc.wave] ?? "Saw"}</div>
          <Slider label="Detune" min={0} max={40} step={1} value={track.osc.detune} onChange={(detune) => set((t) => ({ ...t, osc: { ...t.osc, detune } }))} />
          <Slider label="Sample" min={0} max={1} step={0.01} value={track.sampleStart} onChange={(sampleStart) => set((t) => ({ ...t, sampleStart }))} />
          <select className="select" aria-label="Sampler source" value={track.sampleId ?? ""} onChange={(e) => set((t) => ({ ...t, sampleId: e.target.value || null }))}>
            <option value="">No sample</option>
            {song.clips.map((c) => (
              <option key={c.id} value={c.id}>{c.name}</option>
            ))}
          </select>
        </article>
        <Device title="Filter" bypass={track.bypass.filter} onBypass={() => toggleBypass(track, "filter")}>
          <Slider label="Cutoff" min={0} max={1} step={0.01} value={track.filter.cutoff} onChange={(cutoff) => set((t) => ({ ...t, filter: { ...t.filter, cutoff } }))} />
          <Slider label="Resonance" min={0} max={1} step={0.01} value={track.filter.resonance} onChange={(resonance) => set((t) => ({ ...t, filter: { ...t.filter, resonance } }))} />
          <Slider label="LFO rate" min={0.05} max={1} step={0.01} value={track.lfo.rate} onChange={(rate) => set((t) => ({ ...t, lfo: { ...t.lfo, rate } }))} />
        </Device>
        <Device title="Drive" bypass={track.bypass.drive} onBypass={() => toggleBypass(track, "drive")}>
          <Slider label="Amount" min={0} max={1} step={0.01} value={track.drive} onChange={(drive) => set((t) => ({ ...t, drive }))} />
        </Device>
        <Device title="EQ" bypass={track.bypass.eq} onBypass={() => toggleBypass(track, "eq")}>
          <Slider label="Low" min={-12} max={12} step={0.5} value={track.eq.lo} onChange={(lo) => set((t) => ({ ...t, eq: { ...t.eq, lo } }))} />
          <Slider label="Mid" min={-12} max={12} step={0.5} value={track.eq.mid} onChange={(mid) => set((t) => ({ ...t, eq: { ...t.eq, mid } }))} />
          <Slider label="High" min={-12} max={12} step={0.5} value={track.eq.hi} onChange={(hi) => set((t) => ({ ...t, eq: { ...t.eq, hi } }))} />
        </Device>
        <Device title="Compressor" bypass={track.bypass.comp} onBypass={() => toggleBypass(track, "comp")}>
          <Slider label="Threshold" min={-40} max={0} step={1} value={track.comp.threshold} onChange={(threshold) => set((t) => ({ ...t, comp: { ...t.comp, threshold } }))} />
          <Slider label="Ratio" min={1} max={12} step={0.1} value={track.comp.ratio} onChange={(ratio) => set((t) => ({ ...t, comp: { ...t.comp, ratio } }))} />
          <Slider label="Attack" min={0.001} max={0.2} step={0.001} value={track.comp.attack} onChange={(attack) => set((t) => ({ ...t, comp: { ...t.comp, attack } }))} />
          <Slider label="Release" min={0.02} max={0.8} step={0.01} value={track.comp.release} onChange={(release) => set((t) => ({ ...t, comp: { ...t.comp, release } }))} />
        </Device>
        <Device title="Chorus" bypass={track.bypass.chorus} onBypass={() => toggleBypass(track, "chorus")}>
          <Slider label="Mix" min={0} max={1} step={0.01} value={track.chorus} onChange={(chorus) => set((t) => ({ ...t, chorus }))} />
        </Device>
        <Device title="Delay" bypass={track.bypass.delay} onBypass={() => toggleBypass(track, "delay")}>
          <Slider label="Time" min={0.05} max={0.9} step={0.01} value={track.delay.time} onChange={(time) => set((t) => ({ ...t, delay: { ...t.delay, time } }))} />
          <Slider label="Feedback" min={0} max={0.85} step={0.01} value={track.delay.feedback} onChange={(feedback) => set((t) => ({ ...t, delay: { ...t.delay, feedback } }))} />
          <Slider label="Mix" min={0} max={1} step={0.01} value={track.delay.mix} onChange={(mix) => set((t) => ({ ...t, delay: { ...t.delay, mix } }))} />
        </Device>
        <Device title="Space" bypass={track.bypass.space} onBypass={() => toggleBypass(track, "space")}>
          <Slider label="Send" min={0} max={1} step={0.01} value={track.space} onChange={(space) => set((t) => ({ ...t, space }))} />
        </Device>
        <article className="device">
          <h3>Macros</h3>
          {track.macros.map((value, i) => (
            <Slider key={i} label={`Macro ${i + 1}`} min={0} max={1} step={0.01} value={value} onChange={(next) => set((t) => {
              const macros = [...t.macros] as Track["macros"];
              macros[i] = next;
              return { ...t, macros };
            })} />
          ))}
        </article>
        <article className="device">
          <h3>Mod matrix</h3>
          {track.mod.map((slot, i) => (
            <div className="row" key={i}>
              <select className="select" aria-label={`Source ${i + 1}`} value={slot.source} onChange={(e) => setMod(track, i, { source: e.target.value as ModSource })}>
                {["lfo", "macro1", "macro2", "velocity"].map((s) => <option key={s} value={s}>{s}</option>)}
              </select>
              <select className="select" aria-label={`Destination ${i + 1}`} value={slot.dest} onChange={(e) => setMod(track, i, { dest: e.target.value as ModDest })}>
                {["cutoff", "pitch", "drive", "space"].map((s) => <option key={s} value={s}>{s}</option>)}
              </select>
              <input className="field" aria-label={`Amount ${i + 1}`} type="number" min={0} max={1} step={0.05} value={slot.amount} onChange={(e) => setMod(track, i, { amount: Number(e.target.value) })} />
            </div>
          ))}
        </article>
        {track.voice && (
          <article className="device">
            <h3>Test bank</h3>
            <div className="row">
              {TEST_BANKS.map((bank) => (
                <button
                  key={bank.id}
                  className={`btn ${voicebank(song.voicebank).id === bank.id ? "btn-on" : ""}`}
                  onClick={() => {
                    useMelos.getState().patchSong({ voicebank: bank.id });
                    useMelos.getState().setStatus(`${bank.name} test bank`);
                  }}
                >
                  {bank.name}
                </button>
              ))}
            </div>
            <p className="mist">{voicebank(song.voicebank).credit}</p>
          </article>
        )}
        {track.voice && (
          <article className="device">
            <h3>Vocal expression</h3>
            <Slider label="Breath" min={0} max={1} step={0.01} value={track.expression.breath} onChange={(breath) => set((t) => ({ ...t, expression: { ...t.expression, breath } }))} />
            <Slider label="Tension" min={0} max={1} step={0.01} value={track.expression.tension} onChange={(tension) => set((t) => ({ ...t, expression: { ...t.expression, tension } }))} />
            <Slider label="Power" min={0} max={1} step={0.01} value={track.expression.power} onChange={(power) => set((t) => ({ ...t, expression: { ...t.expression, power } }))} />
            <Slider label="Energy" min={0} max={1} step={0.01} value={track.expression.energy} onChange={(energy) => set((t) => ({ ...t, expression: { ...t.expression, energy } }))} />
            <Slider label="Vibrato" min={0} max={1} step={0.01} value={track.expression.vibrato} onChange={(vibrato) => set((t) => ({ ...t, expression: { ...t.expression, vibrato } }))} />
            <Slider label="Formant" min={-6} max={6} step={0.1} value={track.expression.formant} onChange={(formant) => set((t) => ({ ...t, expression: { ...t.expression, formant } }))} />
          </article>
        )}
      </div>
    </div>
  );
}

function Device({ title, bypass, onBypass, children }: { title: string; bypass: boolean; onBypass: () => void; children: ReactNode }) {
  return (
    <article className="device">
      <h3>
        {title}
        <button className={`btn ${bypass ? "" : "btn-on"}`} onClick={onBypass}>{bypass ? "Bypassed" : "On"}</button>
      </h3>
      {children}
    </article>
  );
}

function toggleBypass(track: Track, key: keyof Bypass) {
  useMelos.getState().updateTrack(track.id, (t) => ({ ...t, bypass: { ...t.bypass, [key]: !t.bypass[key] } }));
}

function setMod(track: Track, index: number, partial: Partial<Track["mod"][number]>) {
  useMelos.getState().updateTrack(track.id, (t) => {
    const mod = [...t.mod] as Track["mod"];
    const current = mod[index];
    if (!current) return t;
    mod[index] = { ...current, ...partial };
    return { ...t, mod };
  });
}
