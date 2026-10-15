import { test } from "node:test";
import assert from "node:assert/strict";
import { matchesHotkey } from "../src/lib/hotkeys";

const key = (k: string, o: Partial<{ meta: boolean; ctrl: boolean; shift: boolean; alt: boolean; code: string }> = {}) => ({
  key: k, code: o.code ?? "", metaKey: !!o.meta, ctrlKey: !!o.ctrl, shiftKey: !!o.shift, altKey: !!o.alt,
});
const quickAsk = { modifiers: ["Mod", "Shift"], key: "k" };

test("Mod+Shift+K is Cmd+Shift+K on macOS, Ctrl+Shift+K elsewhere", () => {
  assert.ok(matchesHotkey(key("K", { meta: true, shift: true }), quickAsk, true));
  assert.ok(!matchesHotkey(key("K", { ctrl: true, shift: true }), quickAsk, true));
  assert.ok(matchesHotkey(key("K", { ctrl: true, shift: true }), quickAsk, false));
});

test("extra or missing modifiers don't match", () => {
  assert.ok(!matchesHotkey(key("k", { meta: true }), quickAsk, true));
  assert.ok(!matchesHotkey(key("K", { meta: true, shift: true, alt: true }), quickAsk, true));
  assert.ok(!matchesHotkey(key("j", { meta: true, shift: true }), quickAsk, true));
});

test("layout-independent fallback on the physical key", () => {
  // e.g. a layout where Shift+K produces another character
  assert.ok(matchesHotkey(key("Ķ", { meta: true, shift: true, code: "KeyK" }), quickAsk, true));
});

test("a rebound hotkey (Ctrl+Alt+A) is honoured", () => {
  assert.ok(matchesHotkey(key("a", { ctrl: true, alt: true }), { modifiers: ["Ctrl", "Alt"], key: "A" }, true));
});
