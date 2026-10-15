import type { Segment } from './types';

/** Immutable presentation grouping; every original id/time remains available for citations. */
export function transcriptTurns(segments: Segment[]): Segment[] {
  const turns: Segment[] = [];
  for (const segment of [...segments].sort((a, b) => a.start - b.start)) {
    const last = turns.at(-1);
    const key = segment.speakerId;
    if (last && segment.final && last.final && key && last.speakerId === key && last.source === segment.source &&
        !key.endsWith(':unknown') && !key.endsWith('-0') && last.speaker === segment.speaker &&
        segment.start - (last.end ?? last.start) <= 1.5 && (segment.end ?? segment.start) - last.start <= 30 &&
        last.text.split(/\s+/).length < 60 && !(/[.?!]$/.test(last.text) && last.text.split(/\s+/).length >= 12)) {
      last.text += ' ' + segment.text;
      last.end = Math.max(last.end ?? last.start, segment.end ?? segment.start);
    } else turns.push({ ...segment });
  }
  return turns;
}
