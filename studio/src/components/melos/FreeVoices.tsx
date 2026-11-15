import { useEffect } from "react";
import { ensureSampleBank, freeVoice, freeVoices, isFreeVoiceId, loadFreeCatalog, loadState, useFreeVoiceStore } from "@/lib/melos/freevoices";
import { useMelos } from "@/lib/melos/store";
import { voicebank } from "@/lib/melos/voicebanks";

/** Id of the active built-in test bank, or "" while a free voice is active. */
export function activeTestBankId(id: string | undefined) {
  return isFreeVoiceId(id) ? "" : voicebank(id).id;
}

/** Credit line for whichever voice is active (built-in test bank text, or the free voice credit with link). */
export function BankCredit({ id }: { id: string | undefined }) {
  useFreeVoiceStore();
  const free = freeVoice(id);
  if (!isFreeVoiceId(id)) return <p className="mist">{voicebank(id).credit}</p>;
  if (!free) return <p className="mist">Loading voice credit…</p>;
  return (
    <p className="mist" data-testid="free-voice-credit">
      <a href={free.credit.url} target="_blank" rel="noopener noreferrer">{free.credit.text}</a>
      {" · "}
      <a href={free.license.termsUrl} target="_blank" rel="noopener noreferrer">terms</a>
    </p>
  );
}

export function FreeVoicePicker({ heading = "Free voices" }: { heading?: string }) {
  useFreeVoiceStore();
  const song = useMelos((s) => s.song);
  useEffect(() => {
    void loadFreeCatalog();
  }, []);
  const voices = freeVoices();
  if (!voices.length) return null;
  const active = freeVoice(song.voicebank);
  return (
    <div className="stack" data-testid="free-voices">
      <h4>{heading}</h4>
      <p className="mist">Real singing voices rendered offline from free banks. They load only when you pick one; the test banks keep working as before.</p>
      <div className="row">
        {voices.map((voice) => {
          const state = loadState(voice.id);
          return (
            <button
              key={voice.id}
              data-testid={`free-voice-${voice.id}`}
              className={`btn ${song.voicebank === voice.id ? "btn-on" : ""}`}
              onClick={() => {
                useMelos.getState().patchSong({ voicebank: voice.id });
                useMelos.getState().setStatus(`${voice.name} loading…`);
                void ensureSampleBank(voice.id).then((ok) =>
                  useMelos.getState().setStatus(ok ? `${voice.name} ready` : `${voice.name} could not load, using Lamp`),
                );
              }}
            >
              {voice.name}
              {state === "loading" ? " …" : ""}
            </button>
          );
        })}
      </div>
      {active && (
        <p className="mist">
          {active.languageNote} {active.license.summary}{" "}
          <a href={active.source.url} target="_blank" rel="noopener noreferrer">Source: {active.source.name}</a>
        </p>
      )}
    </div>
  );
}
