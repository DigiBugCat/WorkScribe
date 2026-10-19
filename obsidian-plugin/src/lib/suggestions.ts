// User text and AI text are separate. Only explicit edits transfer AI ownership.
import type { Enhancement, Note } from "./types";
export type LineState =
  | { kind: "sending"; error?: string }
  | { kind: "waiting"; drafting: boolean }
  | { kind: "none"; hint: string }
  | { kind: "ai" | "owned"; enhanced: Enhancement };
export const NO_MATCH = "No matching discussion yet";
export function lineState(note: Note): LineState {
  if (note.enhanced && (note.enhanced.text || note.enhanced.topic))
    return { kind: note.userEdited ? "owned" : "ai", enhanced: note.enhanced };
  if (note.state === "listening" || note.state === "found") return { kind: "waiting", drafting: note.state === "found" };
  return { kind: "none", hint: friendlyHint(note.hint) };
}
export function friendlyHint(hint: string | undefined): string {
  return (hint ?? "").replace(/\s*Kept as typed\.?\s*/i, " ").trim().replace(/\.$/, "") || NO_MATCH;
}
