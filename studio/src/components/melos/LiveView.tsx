import { useEffect, useRef, useState } from "react";
import { hasPerformerToken, performerChangePassword, performerLogin, performerLogout, setPerformerToken, useArcis } from "@/lib/engine";
import { runCrowdPrompt, runEnginePedalTransition, runLiveStep, runSubmitEnginePedal } from "@/lib/melos/arcis-actions";
import { getMeter } from "@/lib/melos/engine";
import { exportPacket } from "@/lib/melos/commands";
import { useMelos } from "@/lib/melos/store";
import type { TrackKind, VocalEngine } from "@/lib/melos/types";
import { TEST_BANKS, voicebank } from "@/lib/melos/voicebanks";
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
  const link = useArcis((s) => s.link);
  const caps = useArcis((s) => s.caps);
  const signedIn = useArcis((s) => s.signedIn);
  const crowdPedals = useArcis((s) => s.crowdPedals);
  const canStep = signedIn || caps.step;

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
        <form className="stack" onSubmit={(e) => { e.preventDefault(); void runCrowdPrompt(text); }}>
          <label className="stack">
            <span className="mist">Crowd prompt</span>
            <input className="field" value={text} onChange={(e) => setText(e.target.value)} aria-label="Crowd prompt" />
          </label>
          <button className="btn btn-primary" type="submit">Modulate</button>
        </form>
        <div className="row">
          {["breathier", "lift the chorus", "darker", "sparser", "higher"].map((p) => (
            <button key={p} className="btn" onClick={() => void runCrowdPrompt(p)}>{p}</button>
          ))}
        </div>
        {song.prompts.map((p) => (
          <div key={p.id} className="prompt">
            <small>{p.effect}</small>
            <div>{p.text}</div>
          </div>
        ))}
        {canStep && (
          <button className="btn btn-primary" type="button" onClick={() => void runLiveStep()}>
            Engine live step
          </button>
        )}
        {link === "connected" && (
          <div className="panel stack">
            <h3>Crowd pedals</h3>
            <p className="mist">From the shared Arcis engine. Approve/activate stays on the performer route.</p>
            {crowdPedals.length === 0 && <p className="mist">No crowd pedals yet.</p>}
            {crowdPedals.map((p) => (
              <div key={p.id} className="prompt">
                <strong>{p.name}</strong>
                <div className="mist">#{p.id} · {p.author} · {p.target_instrument} · {p.status}</div>
                {signedIn && (
                  <div className="row">
                    <button className="btn btn-primary" type="button" onClick={() => void runEnginePedalTransition("approve", p.id)}>Approve</button>
                    <button className="btn" type="button" onClick={() => void runEnginePedalTransition("activate", p.id)}>Activate</button>
                    <button className="btn" type="button" onClick={() => void runEnginePedalTransition("reject", p.id)}>Reject</button>
                    <button className="btn" type="button" onClick={() => void runEnginePedalTransition("deactivate", p.id)}>Deactivate</button>
                  </div>
                )}
              </div>
            ))}
          </div>
        )}
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
          <h3>Free test banks</h3>
          <p className="mist">Original Melos timbres so you can hear vowels before a purchased bank. These are not VOCALOID, Synthesizer V, ACE, or Emvoice.</p>
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
        <PerformerSignIn />
        <PerformerTokenField />
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
      void runSubmitEnginePedal({ name, author, target, reverb, breath });
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


function PerformerSignIn() {
  const signedIn = useArcis((s) => s.signedIn);
  const performer = useArcis((s) => s.performer);
  const [busy, setBusy] = useState(false);
  const [changing, setChanging] = useState(false);

  return (
    <div className="panel stack performer-auth">
      <h3>Performer sign-in</h3>
      {signedIn ? (
        <>
          <p className="mist">Signed in as <strong>{performer || "performer"}</strong>. Generate, live step, and pedal approval use this session.</p>
          {changing ? (
            <form
              className="stack"
              onSubmit={(e) => {
                e.preventDefault();
                const data = new FormData(e.currentTarget);
                const current = String(data.get("current") ?? "");
                const next = String(data.get("next") ?? "");
                const confirm = String(data.get("confirm") ?? "");
                if (next !== confirm) {
                  useMelos.getState().setStatus("New passwords do not match");
                  return;
                }
                setBusy(true);
                void performerChangePassword(current, next).then((result) => {
                  setBusy(false);
                  if (result.ok) {
                    setChanging(false);
                    useMelos.getState().setStatus("Password updated");
                    e.currentTarget.reset();
                  } else {
                    useMelos.getState().setStatus(result.error || "Could not update password");
                  }
                });
              }}
            >
              <input className="field" type="password" name="current" autoComplete="current-password" placeholder="current password" aria-label="Current password" required />
              <input className="field" type="password" name="next" autoComplete="new-password" placeholder="new password" aria-label="New password" required minLength={8} />
              <input className="field" type="password" name="confirm" autoComplete="new-password" placeholder="confirm new password" aria-label="Confirm new password" required minLength={8} />
              <div className="row">
                <button className="btn btn-primary" type="submit" disabled={busy}>Save password</button>
                <button className="btn" type="button" onClick={() => setChanging(false)}>Cancel</button>
              </div>
            </form>
          ) : (
            <div className="row">
              <button className="btn" type="button" onClick={() => setChanging(true)}>Change password</button>
              <button
                className="btn"
                type="button"
                disabled={busy}
                onClick={() => {
                  setBusy(true);
                  void performerLogout().then(() => {
                    setBusy(false);
                    useMelos.getState().setStatus("Signed out");
                  });
                }}
              >
                Sign out
              </button>
            </div>
          )}
        </>
      ) : (
        <form
          className="stack"
          onSubmit={(e) => {
            e.preventDefault();
            const data = new FormData(e.currentTarget);
            const username = String(data.get("username") ?? "").trim();
            const password = String(data.get("password") ?? "");
            if (!username || !password) {
              useMelos.getState().setStatus("Enter a username and password");
              return;
            }
            setBusy(true);
            void performerLogin(username, password).then((result) => {
              setBusy(false);
              if (result.ok) {
                useMelos.getState().setStatus(`Signed in as ${result.data.username ?? username}`);
              } else if (result.status === 404) {
                useMelos.getState().setStatus("Sign-in is not exposed yet (Caddy has not proxied the auth routes)");
              } else {
                useMelos.getState().setStatus(result.error || "Sign-in failed");
              }
            });
          }}
        >
          <p className="mist">Sign in to enable generate, live step, and pedal approval. The token field below still works as a fallback.</p>
          <input className="field" type="text" name="username" autoComplete="username" placeholder="username" aria-label="Performer username" required />
          <input className="field" type="password" name="password" autoComplete="current-password" placeholder="password" aria-label="Performer password" required />
          <button className="btn btn-primary" type="submit" disabled={busy}>Sign in</button>
        </form>
      )}
    </div>
  );
}

function PerformerTokenField() {
  const [on, setOn] = useState(hasPerformerToken);
  return (
    <form
      className="panel stack"
      onSubmit={(e) => {
        e.preventDefault();
        const data = new FormData(e.currentTarget);
        const value = String(data.get("token") ?? "");
        setPerformerToken(value);
        setOn(Boolean(value.trim()));
        e.currentTarget.reset();
        useMelos.getState().setStatus(value.trim() ? "Performer token stored for this session" : "Performer token cleared");
      }}
    >
      <h3>Performer token</h3>
      <p className="mist">
        Optional. The engine only checks a JSON <code>token</code> field, and only when MELOS_PERFORMER_TOKEN is set on the server. Stored in this tab only, never sent until you use generate or live step.
        {on ? " A token is stored in this session." : ""}
      </p>
      <input className="field" type="password" name="token" aria-label="Performer token" autoComplete="off" placeholder="optional" />
      <button className="btn" type="submit">Store token</button>
    </form>
  );
}
