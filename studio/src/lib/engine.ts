/**
 * Arcis engine bridge — talks to /api/melos/* on the same origin.
 *
 * Additive only: if the engine is unreachable or returns 403/404, the studio
 * stays in local mode and existing desks, banks, and browser audio keep working.
 *
 * Auth: the running engine checks MELOS_PERFORMER_TOKEN against a JSON body
 * field named `token` (see src/media/melos/api.zig performerOk). It does not
 * currently read headers. We still send X-Melos-Performer when a token is
 * present so a future header check will work. The token is never logged.
 */
import { create } from "zustand";

export const MODULATE_COOLDOWN_MS = 400;
export const SUBMIT_COOLDOWN_MS = 1000;
export const BODY_CAP = 2048;
const FETCH_MS = 8000;
const POLL_MS = 2000;
const POLL_MAX_MS = 16000;
const TOKEN_KEY = "melos.performerToken";

export type EngineLink = "connected" | "local";

export type ModTargets = {
  tempo_bpm: number;
  density: number;
  energy: number;
  syncopation: number;
  register: number;
  mode: string | null;
};

export type ModulateOk = {
  status: "ok";
  summary: string;
  applied: number;
  targets: ModTargets;
  current?: {
    tempo_bpm: number;
    density: number;
    energy: number;
    syncopation: number;
    register: number;
    sevenths?: boolean;
  };
  tempo_bpm: number;
};

export type EnginePedal = {
  id: number;
  name: string;
  author: string;
  target_instrument: string;
  description: string;
  status: string;
  pitch_shift: number;
  velocity_scale: number;
  density_scale: number;
  reverb_amount: number;
  delay_ticks: number;
};

export type EngineNote = {
  pitch: number;
  velocity: number;
  start_tick: number;
  duration_ticks: number;
  channel: number;
};

export type StepOk = {
  status: "ok";
  bar: number;
  tick: number;
  next_tick: number;
  phrase: string;
  bar_in_phrase: number;
  chord: string;
  key: string;
  tempo_bpm: number;
  pedals_active: number;
  params?: {
    tempo_bpm: number;
    density: number;
    energy: number;
    syncopation: number;
    register: number;
    sevenths?: boolean;
  };
  notes: EngineNote[];
};

export type GenerateTrack = {
  name: string;
  role: string;
  program: number;
  events: EngineNote[];
};

export type GenerateOk = {
  status: "ok";
  notes: number;
  seed: number;
  piece: {
    ticks_per_quarter: number;
    attributes?: {
      key?: string;
      emotion?: string;
      tempo_bpm?: number;
      density?: number;
      bars?: number;
    };
    tracks: GenerateTrack[];
  };
};

export type EngineFail = {
  ok: false;
  status: number;
  error: string;
  retryAfterMs?: number;
  unreachable?: boolean;
};

export const ENGINE_INSTRUMENTS = [
  "Piano",
  "Electric Piano",
  "Synth Lead",
  "Synth Pad",
  "Bass",
  "Drums",
  "Guitar",
  "Strings",
  "Flute",
  "Choir",
] as const;

export type EngineInstrument = (typeof ENGINE_INSTRUMENTS)[number];

/** Map a studio track kind onto an instrument name the engine will accept. */
export function instrumentForTarget(target: string): EngineInstrument {
  switch (target) {
    case "vocal":
      return "Flute";
    case "harmony":
      return "Choir";
    case "bass":
      return "Bass";
    case "drums":
      return "Drums";
    case "pad":
      return "Synth Pad";
    case "audio":
      return "Guitar";
    default:
      return "Piano";
  }
}

export function getPerformerToken(): string | undefined {
  try {
    const value = sessionStorage.getItem(TOKEN_KEY);
    return value && value.trim() ? value.trim() : undefined;
  } catch {
    return undefined;
  }
}

/** Store the optional performer token in sessionStorage only. Never log it. */
export function setPerformerToken(token: string | undefined) {
  try {
    if (!token || !token.trim()) sessionStorage.removeItem(TOKEN_KEY);
    else sessionStorage.setItem(TOKEN_KEY, token.trim());
  } catch {
    /* private-mode / blocked storage */
  }
}

export function hasPerformerToken(): boolean {
  return Boolean(getPerformerToken());
}

type JsonOk<T> = { ok: true; status: number; data: T };
type JsonResult<T> = JsonOk<T> | EngineFail;

async function request<T>(path: string, init: RequestInit & { timeoutMs?: number } = {}): Promise<JsonResult<T>> {
  const body = typeof init.body === "string" ? init.body : undefined;
  if (body && body.length > BODY_CAP) {
    return { ok: false, status: 413, error: "request too large" };
  }
  const headers = new Headers(init.headers);
  headers.set("Accept", "application/json");
  if (body) headers.set("Content-Type", "application/json");
  const token = getPerformerToken();
  if (token) headers.set("X-Melos-Performer", token);

  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), init.timeoutMs ?? FETCH_MS);
  try {
    const res = await fetch(path, {
      ...init,
      body,
      headers,
      signal: ac.signal,
      credentials: "same-origin",
    });
    const text = await res.text();
    let data: unknown = null;
    if (text) {
      try {
        data = JSON.parse(text);
      } catch {
        data = null;
      }
    }
    if (!res.ok) {
      const err = (data && typeof data === "object" && "error" in data && typeof (data as { error: unknown }).error === "string"
        ? (data as { error: string }).error
        : res.statusText) || "request failed";
      const retry =
        data && typeof data === "object" && "retry_after_ms" in data
          ? Number((data as { retry_after_ms: unknown }).retry_after_ms)
          : undefined;
      return {
        ok: false,
        status: res.status,
        error: err,
        retryAfterMs: Number.isFinite(retry) ? retry : undefined,
        unreachable: res.status === 404 || res.status === 403,
      };
    }
    return { ok: true, status: res.status, data: data as T };
  } catch (err) {
    const aborted = err instanceof DOMException && err.name === "AbortError";
    return {
      ok: false,
      status: 0,
      error: aborted ? "timeout" : "unreachable",
      unreachable: true,
    };
  } finally {
    clearTimeout(timer);
  }
}

function withToken<T extends Record<string, unknown>>(body: T): T & { token?: string } {
  const token = getPerformerToken();
  return token ? { ...body, token } : body;
}

function payload(data: Record<string, unknown>): string {
  return JSON.stringify(data);
}

let lastModulateAt = 0;
let lastSubmitAt = 0;

async function respectCooldown(last: number, min: number) {
  const wait = min - (Date.now() - last);
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
}

export async function modulate(prompt: string): Promise<JsonResult<ModulateOk>> {
  await respectCooldown(lastModulateAt, MODULATE_COOLDOWN_MS);
  lastModulateAt = Date.now();
  return request<ModulateOk>("/api/melos/live/modulate", {
    method: "POST",
    body: payload({ prompt }),
  });
}

export async function listPedals(): Promise<JsonResult<{ pedals: EnginePedal[] }>> {
  return request<{ pedals: EnginePedal[] }>("/api/melos/pedals", { method: "GET", timeoutMs: 5000 });
}

export async function submitPedal(input: {
  name: string;
  author?: string;
  target_instrument: string;
  description?: string;
  pitch_shift?: number;
  velocity_scale?: number;
  density_scale?: number;
  reverb_amount?: number;
  delay_ticks?: number;
}): Promise<JsonResult<{ status: string; id?: number }>> {
  await respectCooldown(lastSubmitAt, SUBMIT_COOLDOWN_MS);
  lastSubmitAt = Date.now();
  return request("/api/melos/pedals/submit", {
    method: "POST",
    body: payload({
      name: input.name,
      author: input.author ?? "crowd",
      target_instrument: input.target_instrument,
      description: input.description ?? "",
      pitch_shift: input.pitch_shift ?? 0,
      velocity_scale: input.velocity_scale ?? 1,
      density_scale: input.density_scale ?? 1,
      reverb_amount: input.reverb_amount ?? 0,
      delay_ticks: input.delay_ticks ?? 0,
    }),
  });
}

export async function liveStep(input: {
  base_prompt?: string;
  tempo_bpm?: number;
  density?: number;
  current_tick?: number;
  seed?: number;
  reset?: boolean;
} = {}): Promise<JsonResult<StepOk>> {
  return request<StepOk>("/api/melos/live/step", {
    method: "POST",
    body: payload(withToken({ ...input })),
    timeoutMs: 12000,
  });
}

export async function generate(input: {
  seed?: number;
  bars?: number;
  text?: string;
  attributes?: { key?: string; emotion?: string; tempo_bpm?: number; density?: number };
} = {}): Promise<JsonResult<GenerateOk>> {
  return request<GenerateOk>("/api/melos/generate", {
    method: "POST",
    body: payload(withToken({ ...input })),
    timeoutMs: 15000,
  });
}

export async function pedalTransition(
  action: "approve" | "activate" | "reject" | "deactivate",
  id: number,
): Promise<JsonResult<{ status: string; id?: number; pedal_status?: string }>> {
  return request(`/api/melos/pedals/${action}`, {
    method: "POST",
    body: payload(withToken({ id })),
    timeoutMs: 8000,
  });
}

export async function performerLogin(username: string, password: string): Promise<JsonResult<{ status: string; username?: string }>> {
  const result = await request<{ status: string; username?: string }>("/api/melos/auth/login", {
    method: "POST",
    body: payload({ username, password }),
    timeoutMs: 15000,
  });
  if (result.ok) {
    useArcis.setState({ signedIn: true, performer: result.data.username ?? username.trim() });
  }
  return result;
}

export async function performerLogout(): Promise<void> {
  await request("/api/melos/auth/logout", { method: "POST", body: payload({}), timeoutMs: 8000 });
  useArcis.setState({ signedIn: false, performer: "" });
}

export async function performerChangePassword(current: string, next: string): Promise<JsonResult<{ status: string }>> {
  return request("/api/melos/auth/password", {
    method: "POST",
    body: payload({ current, new: next }),
    timeoutMs: 15000,
  });
}

export async function refreshPerformer(): Promise<void> {
  const result = await request<{ username?: string }>("/api/melos/auth/me", { method: "GET", timeoutMs: 5000 });
  if (result.ok) {
    useArcis.setState({ signedIn: true, performer: result.data.username ?? "" });
  } else {
    useArcis.setState({ signedIn: false, performer: "" });
  }
}

export function canUsePerformerRoutes(): boolean {
  const s = useArcis.getState();
  return s.signedIn || s.caps.generate || s.caps.step || hasPerformerToken();
}

/**
 * Discover whether a performer route is proxied.
 * GET only — never POST (live/step would start a session).
 * Caddy's closed handle returns an empty 404; a JSON 404/403 means the engine saw it.
 */
async function routeReachable(path: string): Promise<boolean> {
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), 4000);
  try {
    const res = await fetch(path, { method: "GET", signal: ac.signal, credentials: "same-origin" });
    if (res.status === 404 || res.status === 405) {
      const text = await res.text();
      if (!text) return false;
      try {
        JSON.parse(text);
        return true;
      } catch {
        return false;
      }
    }
    return res.status !== 0;
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

export type ArcisState = {
  link: EngineLink;
  detail: string;
  caps: { generate: boolean; step: boolean };
  crowdPedals: EnginePedal[];
  probing: boolean;
  signedIn: boolean;
  performer: string;
};

export const useArcis = create<ArcisState>(() => ({
  link: "local",
  detail: "checking the engine",
  caps: { generate: false, step: false },
  crowdPedals: [],
  probing: true,
  signedIn: false,
  performer: "",
}));

let pollTimer: ReturnType<typeof setTimeout> | null = null;
let started = false;
let delay = POLL_MS;
let capsChecked = false;

function goLocal(detail: string) {
  useArcis.setState({ link: "local", detail, crowdPedals: useArcis.getState().crowdPedals, probing: false });
}

function goConnected(pedals: EnginePedal[]) {
  delay = POLL_MS;
  useArcis.setState({ link: "connected", detail: "Arcis engine", crowdPedals: pedals, probing: false });
}

async function tick() {
  const result = await listPedals();
  if (result.ok) {
    const pedals = Array.isArray(result.data.pedals) ? result.data.pedals : [];
    goConnected(pedals);
    if (!capsChecked) {
      capsChecked = true;
      const [generateOk, stepOk] = await Promise.all([
        routeReachable("/api/melos/generate"),
        routeReachable("/api/melos/live/step"),
      ]);
      useArcis.setState({ caps: { generate: generateOk, step: stepOk } });
    }
    delay = POLL_MS;
  } else if (result.status === 403 || result.status === 404 || result.unreachable) {
    goLocal(result.error === "timeout" ? "engine timed out" : "engine unreachable");
    capsChecked = false;
    useArcis.setState({ caps: { generate: false, step: false } });
    delay = Math.min(delay * 2, POLL_MAX_MS);
  } else {
    delay = Math.min(delay * 2, POLL_MAX_MS);
    useArcis.setState({ probing: false, detail: result.error });
  }
  if (started) pollTimer = setTimeout(() => void tick(), delay);
}

/** Start the pedals poll. Call once from the studio root. */
export function startArcisBridge(): () => void {
  if (started) return stopArcisBridge;
  started = true;
  delay = POLL_MS;
  void refreshPerformer();
  void tick();
  return stopArcisBridge;
}

export function stopArcisBridge() {
  started = false;
  if (pollTimer) {
    clearTimeout(pollTimer);
    pollTimer = null;
  }
}
