/** Studio-side actions that layer Arcis engine results onto the local song. */
import {
  canUsePerformerRoutes,
  generate,
  instrumentForTarget,
  liveStep,
  modulate,
  pedalTransition,
  submitPedal,
  useArcis,
  type EnginePedal,
} from "@/lib/engine";
import { useMelos } from "./store";

export async function runCrowdPrompt(text: string): Promise<void> {
  const trimmed = text.trim();
  if (!trimmed) return;
  const link = useArcis.getState().link;
  if (link === "connected") {
    const result = await modulate(trimmed);
    if (result.ok) {
      useMelos.getState().applyEngineModulation(trimmed, result.data);
      return;
    }
    if (result.status === 429) {
      const wait = result.retryAfterMs ? ` (${result.retryAfterMs} ms)` : "";
      useMelos.getState().setStatus(`Engine · slow down${wait}`);
      return;
    }
    useMelos.getState().applyPrompt(trimmed);
    const why = result.status === 409 ? "no live session" : result.error;
    useMelos.getState().setStatus(`Engine ${why} — applied locally`);
    return;
  }
  useMelos.getState().applyPrompt(trimmed);
}

export async function runSubmitEnginePedal(input: {
  name: string;
  author: string;
  target: string;
  reverb: number;
  breath: number;
}): Promise<void> {
  const name = input.name.trim();
  if (!name) {
    useMelos.getState().setStatus("Pedal needs a name");
    return;
  }
  // Always keep the existing local pedal board.
  useMelos.getState().addPedal({
    name,
    author: input.author || "audience",
    target: (["vocal", "harmony", "bass", "drums", "pad", "audio", "all"].includes(input.target)
      ? input.target
      : "vocal") as "vocal" | "harmony" | "bass" | "drums" | "pad" | "audio" | "all",
    breath: input.breath,
    tension: 0,
    pitch: 0,
    reverb: input.reverb,
    formant: 0,
  });
  if (useArcis.getState().link !== "connected") return;
  const result = await submitPedal({
    name,
    author: input.author || "crowd",
    target_instrument: instrumentForTarget(input.target),
    description: input.breath ? `breath ${input.breath}` : "",
    reverb_amount: input.reverb,
  });
  if (result.ok) {
    useMelos.getState().setStatus(`Engine pedal submitted${result.data.id != null ? ` · #${result.data.id}` : ""}`);
  } else if (result.status === 429) {
    useMelos.getState().setStatus("Engine · slow down (pedal still saved locally)");
  } else {
    useMelos.getState().setStatus(`Engine pedal ${result.error} — saved locally`);
  }
}

export async function runGenerateFromEngine(): Promise<void> {
  if (!canUsePerformerRoutes()) {
    useMelos.getState().setStatus("Sign in as a performer to generate from the engine");
    return;
  }
  const song = useMelos.getState().song;
  const result = await generate({
    bars: 8,
    attributes: {
      tempo_bpm: song.bpm,
      key: keyLabel(song.tonic, song.mode),
      density: 0.45,
    },
  });
  if (!result.ok) {
    useMelos.getState().setStatus(
      result.status === 401 || result.status === 403
        ? "Sign in required for generate"
        : result.status === 404
          ? "Generate is not exposed (Caddy has not proxied this route yet)"
          : `Engine generate: ${result.error}`,
    );
    return;
  }
  const piece = result.data.piece;
  useMelos.getState().layerEngineNotes({
    tracks: piece.tracks,
    ticksPerQuarter: piece.ticks_per_quarter || 480,
    originBeat: useMelos.getState().ui.cursor || 0,
    label: `Engine generated ${result.data.notes} notes (seed ${result.data.seed})`,
    tempoBpm: piece.attributes?.tempo_bpm,
    key: piece.attributes?.key,
  });
}

export async function runLiveStep(): Promise<void> {
  if (!canUsePerformerRoutes()) {
    useMelos.getState().setStatus("Sign in as a performer to run a live step");
    return;
  }
  const song = useMelos.getState().song;
  const result = await liveStep({ tempo_bpm: song.bpm });
  if (!result.ok) {
    useMelos.getState().setStatus(
      result.status === 401 || result.status === 403
        ? "Sign in required for live step"
        : result.status === 404
          ? "Live step is not exposed (Caddy has not proxied this route yet)"
          : `Engine step: ${result.error}`,
    );
    return;
  }
  const step = result.data;
  const origin = step.bar * song.numerator;
  useMelos.getState().layerEngineNotes({
    notes: step.notes,
    ticksPerQuarter: 480,
    originBeat: origin,
    label: `Engine step bar ${step.bar} · ${step.phrase} · ${step.chord}`,
    tempoBpm: step.tempo_bpm,
    key: step.key,
  });
}

export function pedalHeadline(p: EnginePedal): string {
  return `${p.name} · ${p.target_instrument} · ${p.status}`;
}

function keyLabel(tonic: number, mode: string): string {
  const names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"];
  return `${names[tonic] ?? "C"} ${mode}`;
}

export async function runEnginePedalTransition(
  action: "approve" | "activate" | "reject" | "deactivate",
  id: number,
): Promise<void> {
  if (!canUsePerformerRoutes()) {
    useMelos.getState().setStatus("Sign in as a performer to change a crowd pedal");
    return;
  }
  const result = await pedalTransition(action, id);
  if (result.ok) {
    useMelos.getState().setStatus(`Engine pedal #${id} ${result.data.pedal_status ?? action}`);
  } else {
    useMelos.getState().setStatus(
      result.status === 401 || result.status === 403
        ? "Sign in required to change a crowd pedal"
        : result.status === 404
          ? "Pedal approval is not exposed (Caddy has not proxied this route yet)"
          : `Engine pedal: ${result.error}`,
    );
  }
}
