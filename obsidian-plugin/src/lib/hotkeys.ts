// Matching Obsidian hotkeys against key events, for plugin hotkeys that must
// also work while focus is in one of our own text fields. Pure (unit-tested).

export interface HotkeyLike {
  modifiers: string[];
  key: string;
}

export interface KeyLike {
  key: string;
  code?: string;
  metaKey: boolean;
  ctrlKey: boolean;
  shiftKey: boolean;
  altKey: boolean;
}

/** Does a keydown match an Obsidian hotkey? "Mod" is Cmd on macOS and Ctrl elsewhere. */
export function matchesHotkey(e: KeyLike, h: HotkeyLike, isMac: boolean): boolean {
  const mods = new Set(h.modifiers);
  const wantMeta = mods.has("Meta") || (isMac && mods.has("Mod"));
  const wantCtrl = mods.has("Ctrl") || (!isMac && mods.has("Mod"));
  if (wantMeta !== e.metaKey || wantCtrl !== e.ctrlKey) return false;
  if (mods.has("Shift") !== e.shiftKey || mods.has("Alt") !== e.altKey) return false;
  const want = h.key.toLowerCase();
  const key = e.key.length === 1 ? e.key.toLowerCase() : e.key.toLowerCase();
  return key === want || (want.length === 1 && e.code === `Key${want.toUpperCase()}`);
}
