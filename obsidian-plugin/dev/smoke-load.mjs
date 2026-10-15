#!/usr/bin/env node
// Load the built main.js under Node with a stubbed `obsidian` module, run the
// plugin's onload against the mock server, and drive one jot end to end.
// Not a UI test: DOM calls go to an inert proxy. It catches bundle/load errors,
// missing exports, and wiring mistakes in main.ts.
//
//   npm run build && npm run smoke

import Module from "node:module";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { startMockServer } from "./mock-server.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

// An element/anything that absorbs every call.
const inert = () =>
  new Proxy(function () {}, {
    get: (_t, p) => (p === "then" ? undefined : p === Symbol.toPrimitive ? () => "" : inert()),
    apply: () => inert(),
    construct: () => inert(),
    set: () => true,
  });

class Component {
  register() {}
  registerEvent() {}
  registerDomEvent() {}
  registerInterval(id) {
    clearInterval(id);
    return id;
  }
  addChild(c) {
    return c;
  }
  load() {}
  unload() {}
}
const commands = [];
const views = [];
class Plugin extends Component {
  constructor(app, manifest) {
    super();
    this.app = app;
    this.manifest = manifest;
  }
  registerEditorExtension() {}
  registerView(type) {
    views.push(type);
  }
  addRibbonIcon() {
    return inert();
  }
  addStatusBarItem() {
    return inert();
  }
  addCommand(c) {
    commands.push(c);
    return c;
  }
  addSettingTab() {}
  registerMarkdownCodeBlockProcessor() {}
  registerMarkdownPostProcessor() {}
  async loadData() {
    return this._data;
  }
  async saveData() {}
}
class ItemView extends Component {
  constructor(leaf) {
    super();
    this.leaf = leaf;
    this.contentEl = inert();
  }
}
class Modal extends Component {}
class SuggestModal extends Modal {}
class FuzzySuggestModal extends Modal {}
class PluginSettingTab {}
class FileSystemAdapter { constructor(root) { this.root=root; } getBasePath() { return this.root; } getFullPath(p) { return join(this.root,p); } }
class MarkdownView extends ItemView {}
class TFile { constructor(path) { this.path=path; } }
class TFolder {}
const notices = [];
class Notice {
  constructor(m) {
    notices.push(m);
  }
}

const stub = {
  Plugin, Component, ItemView, Modal, SuggestModal, FuzzySuggestModal, PluginSettingTab, FileSystemAdapter,
  MarkdownView, TFile, TFolder, Notice, MarkdownRenderChild: Component, Menu: class {}, Setting: class {},
  setIcon() {}, setTooltip() {}, normalizePath: (p) => p,
  MarkdownRenderer: { render: async () => {} }, ToggleComponent: class {}, Platform: { isMacOS: true },
  prepareFuzzySearch: () => () => null,
  async requestUrl({ url, method, headers, body }) {
    const r = await fetch(url, { method, headers, body });
    return { status: r.status, text: await r.text() };
  },
};

const origLoad = Module._load;
Module._load = function (request, ...rest) {
  if (request === "obsidian") return stub;
  if (request === "electron") return {};
  return origLoad.call(this, request, ...rest);
};
globalThis.window = globalThis;
globalThis.document = inert();
globalThis.requestAnimationFrame = (f) => setTimeout(f, 0);

const until = async (what, pred, ms = 5000) => {
  const t0 = Date.now();
  while (!pred()) {
    if (Date.now() - t0 > ms) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 25));
  }
};

const dir = mkdtempSync(join(tmpdir(), "ws-smoke-"));
const srv = await startMockServer({ discovery: join(dir, "api.json"), quiet: true, speed: 10, vault: dir });
let failed = false;
try {
  // Compile as CommonJS explicitly (package.json says "type": "module"; Obsidian loads main.js as CJS).
  const file = join(ROOT, "main.js");
  const m = new Module(file);
  m.filename = file;
  m.paths = Module._nodeModulePaths(ROOT);
  m._compile(readFileSync(file, "utf8"), file);
  const mod = m.exports;
  const PluginClass = mod.default ?? mod;
  if (typeof PluginClass !== "function") throw new Error("main.js has no default export class");

  const opened = [];
  const leaf = { openFile: async () => {}, setViewState: async (s) => opened.push(s.type), view: { focusJot() {} } };
  const app = {
    workspace: {
      onLayoutReady: (f) => f(),
      on: () => ({}),
      getLeavesOfType: () => [],
      getLeaf: () => leaf,
      getRightLeaf: () => leaf,
      revealLeaf: async () => {},
      getActiveViewOfType: () => null,
      getActiveFile: () => null,
    },
    vault: { adapter: new FileSystemAdapter(dir), getName: () => "Test", on: () => ({}),
      getAbstractFileByPath: p => new TFile(p), read: f => Promise.resolve(readFileSync(join(dir,f.path),"utf8")),
      process: async (f,fn) => writeFileSync(join(dir,f.path),fn(readFileSync(join(dir,f.path),"utf8"))) },
    metadataCache: { on: () => ({}), getFileCache: () => null },
  };
  const plugin = new PluginClass(app, { id: "workscribe" });
  plugin._data = { apiJsonPath: join(dir, "api.json") };
  await plugin.onload();

  const ids = commands.map((c) => c.id).sort();
  console.log("commands:", ids.join(", "));
  console.log("views:", views.join(", "));
  for (const want of ["start-recording", "stop-recording", "quick-ask", "search-moments", "jot-to-meeting", "open-enhanced-notes", "attach-current-note"])
    if (!ids.includes(want)) throw new Error(`missing command ${want}`);
  const qa = commands.find((c) => c.id === "quick-ask");
  if (JSON.stringify(qa.hotkeys) !== JSON.stringify([{ modifiers: ["Mod", "Shift"], key: "k" }])) throw new Error("quick ask hotkey");

  await until("connection", () => plugin.connState.kind === "online");
  await until("status", () => plugin.live.status);
  console.log("connected; recording =", plugin.live.status.recording);

  await plugin.startRecording("Smoke test call");
  await until("recording", () => plugin.recording && plugin.live.meetingId);
  await until("live view auto-open", () => opened.includes("workscribe-live"));
  console.log("recording", plugin.live.meetingId, "· live view opened");

  await plugin.jot("beta 40 accts, halvorsen first");
  await until("enhanced jot", () => [...plugin.live.notes.values()].some((n) => n.enhanced?.topic === "Beta cohort."));
  await until("segments", () => plugin.live.segments.length > 0);
  console.log("jot enhanced:", [...plugin.live.notes.values()].map((n) => `${n.text} → ${n.enhanced?.topic}`).join("; "));

  await plugin.stopRecording();
  await until("stopped", () => !plugin.recording);
  plugin.onunload();
  console.log("smoke: OK");
} catch (e) {
  failed = true;
  console.error("smoke: FAILED", e);
} finally {
  await srv.close();
  rmSync(dir, { recursive: true, force: true });
  process.exit(failed ? 1 : 0);
}
