import type { Song, Track } from "./types";
import { vocalTrack } from "./theory";

function vlq(n: number) {
  let value = Math.max(0, Math.floor(n));
  const bytes = [value & 0x7f];
  value >>= 7;
  while (value > 0) {
    bytes.unshift((value & 0x7f) | 0x80);
    value >>= 7;
  }
  return bytes;
}

function u32(n: number) {
  return [(n >>> 24) & 0xff, (n >>> 16) & 0xff, (n >>> 8) & 0xff, n & 0xff];
}

function u16(n: number) {
  return [(n >>> 8) & 0xff, n & 0xff];
}

type Ev = { tick: number; data: number[] };

function trackChunk(events: Ev[]) {
  const sorted = [...events].sort((a, b) => a.tick - b.tick || a.data.length - b.data.length);
  const bytes: number[] = [];
  let last = 0;
  for (const ev of sorted) {
    bytes.push(...vlq(ev.tick - last), ...ev.data);
    last = ev.tick;
  }
  bytes.push(...vlq(0), 0xff, 0x2f, 0x00);
  return [...Array.from(new TextEncoder().encode("MTrk")), ...u32(bytes.length), ...bytes];
}

export function songToMidi(song: Song) {
  const tpq = 480;
  const tempo = Math.round(60000000 / song.bpm);
  const tracks = song.tracks.filter((t) => t.notes.length > 0);
  const header = [
    ...Array.from(new TextEncoder().encode("MThd")),
    ...u32(6),
    ...u16(1),
    ...u16(Math.max(1, tracks.length)),
    ...u16(tpq),
  ];
  const body: number[] = [];
  tracks.forEach((track, index) => {
    const events: Ev[] = [
      { tick: 0, data: [0xff, 0x51, 0x03, (tempo >> 16) & 0xff, (tempo >> 8) & 0xff, tempo & 0xff] },
      { tick: 0, data: [0xff, 0x58, 0x04, song.numerator, 2, 24, 8] },
      {
        tick: 0,
        data: [0xc0 | (index % 16), track.kind === "drums" ? 0 : track.kind === "bass" ? 33 : 54],
      },
    ];
    const name = Array.from(new TextEncoder().encode(track.name)).slice(0, 40);
    events.push({ tick: 0, data: [0xff, 0x03, name.length, ...name] });
    for (const note of track.notes) {
      const on = Math.round(note.start * tpq);
      const off = on + Math.max(1, Math.round(note.duration * tpq));
      const ch = track.kind === "drums" ? 9 : index % 16;
      events.push({ tick: on, data: [0x90 | ch, note.pitch & 127, note.velocity & 127] });
      events.push({ tick: off, data: [0x80 | ch, note.pitch & 127, 0] });
    }
    body.push(...trackChunk(events));
  });
  if (tracks.length === 0) body.push(...trackChunk([]));
  return new Uint8Array([...header, ...body]);
}

export function lyricsDocument(song: Song) {
  const vocal = vocalTrack(song);
  const lines = [
    `Melos vocal packet`,
    `Engine: ${song.vocalEngine}`,
    `Title: ${song.title}`,
    `Tempo: ${song.bpm}`,
    `Key: tonic ${song.tonic} ${song.mode}`,
    ``,
    `Import the MIDI into your licensed editor, then paste each syllable onto the matching note.`,
    ``,
  ];
  if (!vocal) return lines.join("\n");
  const notes = [...vocal.notes].sort((a, b) => a.start - b.start);
  let lastSection = "";
  for (const note of notes) {
    const section = song.sections.find(
      (s) => note.start >= s.start && note.start < s.start + s.bars * song.numerator,
    );
    if (section && section.name !== lastSection) {
      lines.push("", `[${section.name}]`);
      lastSection = section.name;
    }
    lines.push(`${note.start.toFixed(2)}\t${note.pitch}\t${note.lyric || "la"}`);
  }
  lines.push("", "Expression", JSON.stringify(vocal.expression, null, 2));
  return lines.join("\n");
}

export function downloadBytes(bytes: Uint8Array, filename: string, type: string) {
  const blob = new Blob([new Uint8Array(bytes)], { type });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

export function trackProgram(track: Track) {
  if (track.kind === "drums") return 0;
  if (track.kind === "bass") return 33;
  if (track.kind === "pad") return 88;
  if (track.voice) return 54;
  return 80;
}
