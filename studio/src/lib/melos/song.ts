import { encodePcm, makeNoise, makeTone } from "./audio";
import { blankTrack, type Note, type Song } from "./types";

function notes(rows: [number, number, number, string][], prefix: string): Note[] {
  return rows.map(([start, duration, pitch, lyric], i) => ({
    id: `${prefix}-${i}`,
    start,
    duration,
    pitch,
    velocity: lyric === "—" ? 78 : 104,
    lyric,
  }));
}

function drumLine(bars: number): Note[] {
  const out: Note[] = [];
  let i = 0;
  for (let bar = 0; bar < bars; bar++) {
    const b = bar * 4;
    const kick = [
      [0, 100],
      [1.5, 70],
      [2, 92],
    ] as const;
    for (const [at, vel] of kick) {
      out.push({ id: `dk-${i++}`, pitch: 36, start: b + at, duration: 0.25, velocity: vel, lyric: "" });
    }
    out.push({ id: `ds-${i++}`, pitch: 38, start: b + 1, duration: 0.25, velocity: 112, lyric: "" });
    out.push({ id: `ds-${i++}`, pitch: 38, start: b + 3, duration: 0.25, velocity: 100, lyric: "" });
    for (let s = 0; s < 8; s++) {
      out.push({
        id: `dh-${i++}`,
        pitch: 42,
        start: b + s * 0.5,
        duration: 0.2,
        velocity: s % 2 === 0 ? 84 : 48,
        lyric: "",
      });
    }
  }
  return out;
}

function bassLine(): Note[] {
  const roots = [45, 45, 41, 43, 45, 41, 36, 40];
  const out: Note[] = [];
  roots.forEach((root, bar) => {
    const b = bar * 4;
    out.push({ id: `b-${bar}-a`, pitch: root, start: b, duration: 1.5, velocity: 108, lyric: "" });
    out.push({ id: `b-${bar}-b`, pitch: root + 12, start: b + 2, duration: 1, velocity: 90, lyric: "" });
    out.push({ id: `b-${bar}-c`, pitch: root + 7, start: b + 3, duration: 0.75, velocity: 84, lyric: "" });
  });
  return out;
}

function padLine(): Note[] {
  const chords: number[][] = [
    [57, 60, 64],
    [57, 60, 64],
    [53, 57, 60],
    [55, 59, 62],
    [57, 60, 64],
    [53, 57, 60],
    [48, 52, 55],
    [52, 56, 59],
  ];
  const out: Note[] = [];
  chords.forEach((chord, bar) => {
    chord.forEach((pitch, i) => {
      out.push({
        id: `p-${bar}-${i}`,
        pitch,
        start: bar * 4,
        duration: 3.5,
        velocity: 62,
        lyric: "",
      });
    });
  });
  return out;
}

export function createSong(): Song {
  const tone = makeTone(220, 1.6, 22050);
  const air = makeNoise(2.2, 22050, 11);
  const vocal = notes(
    [
      [0, 1, 57, "hold"],
      [1, 1, 60, "the"],
      [2, 2, 64, "lamp"],
      [4, 1, 57, "in"],
      [5, 1, 60, "the"],
      [6, 2, 64, "room"],
      [8, 1, 55, "where"],
      [9, 1, 57, "the"],
      [10, 2, 60, "night"],
      [12, 1, 62, "learns"],
      [13, 1, 60, "your"],
      [14, 2, 57, "name"],
      [16, 1, 64, "lift"],
      [17, 1, 67, "it"],
      [18, 2, 69, "high"],
      [20, 1, 64, "let"],
      [21, 1, 67, "it"],
      [22, 2, 69, "burn"],
      [24, 1, 60, "ev"],
      [25, 1, 64, "ry"],
      [26, 1, 67, "sha"],
      [27, 1, 64, "dow"],
      [28, 1, 62, "knows"],
      [29, 1, 60, "the"],
      [30, 2, 57, "turn"],
    ],
    "v",
  );
  const harmony = notes(
    [
      [16, 2, 67, "ah"],
      [18, 2, 72, "ah"],
      [20, 2, 67, "ah"],
      [22, 2, 72, "ah"],
      [24, 2, 64, "ah"],
      [26, 2, 69, "ah"],
      [28, 4, 64, "ah"],
    ],
    "h",
  );

  return {
    title: "Lamp Room",
    bpm: 92,
    tonic: 9,
    mode: "minor",
    numerator: 4,
    denominator: 4,
    lengthBeats: 32,
    loopStart: 0,
    loopEnd: 32,
    loopOn: true,
    metronome: false,
    swing: 0.18,
    structureAware: true,
    master: 0.86,
    vocalEngine: "vocaloid",
    voicebank: "lamp",
    kickChannel: "",
    sections: [
      { id: "sec-verse", name: "Verse", start: 0, bars: 4 },
      { id: "sec-chorus", name: "Chorus", start: 16, bars: 4 },
    ],
    clips: [
      { id: "clip-lamp", name: "Lamp tone", sampleRate: 22050, pcm: encodePcm(tone) },
      { id: "clip-air", name: "Room air", sampleRate: 22050, pcm: encodePcm(air) },
    ],
    markers: [
      { id: "mk-1", clipId: "clip-lamp", sample: 1200, text: "bloom" },
      { id: "mk-2", clipId: "clip-air", sample: 8000, text: "hiss" },
    ],
    prompts: [],
    pedals: [
      {
        id: "ped-room",
        name: "Room air",
        author: "listener",
        target: "vocal",
        breath: 0.18,
        tension: 0,
        pitch: 0,
        reverb: 0.22,
        formant: 0,
        status: "pending",
        enabled: true,
      },
      {
        id: "ped-lift",
        name: "Chorus lift",
        author: "front row",
        target: "vocal",
        breath: -0.04,
        tension: 0.06,
        pitch: 0,
        reverb: 0.12,
        formant: 0.6,
        status: "pending",
        enabled: true,
      },
    ],
    tracks: [
      blankTrack({
        id: "tr-vocal",
        name: "Voice",
        kind: "vocal",
        voice: true,
        notes: vocal,
        filter: { cutoff: 0.62, resonance: 0.7 },
        space: 0.28,
        delay: { time: 0.36, feedback: 0.32, mix: 0.16 },
      }),
      blankTrack({
        id: "tr-harm",
        name: "Harmony",
        kind: "harmony",
        voice: true,
        mute: true,
        gain: 0.55,
        notes: harmony,
        pan: -0.25,
      }),
      blankTrack({
        id: "tr-bass",
        name: "Bass",
        kind: "bass",
        notes: bassLine(),
        osc: { wave: 1, detune: 0 },
        filter: { cutoff: 0.34, resonance: 0.55 },
        drive: 0.22,
        space: 0.04,
        delay: { time: 0.2, feedback: 0.1, mix: 0 },
      }),
      blankTrack({
        id: "tr-drums",
        name: "Pulse kit",
        kind: "drums",
        instrument: "pulse",
        notes: drumLine(8),
        gain: 0.78,
        space: 0.08,
        delay: { time: 0.2, feedback: 0.1, mix: 0.04 },
      }),
      blankTrack({
        id: "tr-pad",
        name: "Filament pad",
        kind: "pad",
        notes: padLine(),
        gain: 0.38,
        pan: 0.2,
        osc: { wave: 0, detune: 14 },
        chorus: 0.42,
        space: 0.4,
        filter: { cutoff: 0.48, resonance: 0.4 },
      }),
      blankTrack({
        id: "tr-audio",
        name: "Tape",
        kind: "audio",
        instrument: "fold",
        voice: false,
        gain: 0.32,
        sampleId: "clip-air",
        regions: [
          {
            id: "rg-air",
            clipId: "clip-air",
            start: 0,
            duration: 8,
            offset: 0,
            gain: 0.45,
            fadeIn: 0.4,
            fadeOut: 0.8,
          },
          {
            id: "rg-lamp",
            clipId: "clip-lamp",
            start: 16,
            duration: 6,
            offset: 0,
            gain: 0.55,
            fadeIn: 0.15,
            fadeOut: 1.1,
          },
        ],
      }),
    ],
  };
}
