# Obsidian vault + Web Clipper for WorkScribe

Researched 2026-10-13. **Verified** means official documentation or inspected source; **reported** means a project's README, without execution; **proposed** means our design/estimate. No browser integration was run. Clipper source: [`6d56d618`](https://github.com/obsidianmd/obsidian-clipper/tree/6d56d618b00bd970aa738d6a7a61edee27783e81), manifest version 1.7.1; store versions may differ. Read alongside `digup-integration.md`.

## Recommendation

**Proposed:** use an optional Obsidian-compatible vault as the canonical store for meeting notes, enhanced notes, people and clips. Index it as a WorkScribe Source. Keep recordings, recovery journals, model files and rebuildable embeddings in WorkScribe's application storage. Start with official Web Clipper and a supplied template; add our extension only for live meeting/Ask routing. Obsidian is an optional editor and clipping receiver, not WorkScribe's runtime.

## 1. What official Web Clipper provides

**Verified:** supports Chrome and Chromium browsers including Brave/Arc, Edge, Firefox/Firefox Mobile, and Safari on macOS/iOS/iPadOS. The extension is [MIT licensed](https://github.com/obsidianmd/obsidian-clipper/blob/6d56d618b00bd970aa738d6a7a61edee27783e81/LICENSE), not evidence that the Obsidian app is MIT. [Browser list](https://help.obsidian.md/web-clipper).

**Saving:** [`saveToObsidian`](https://github.com/obsidianmd/obsidian-clipper/blob/6d56d618b00bd970aa738d6a7a61edee27783e81/src/utils/obsidian-note-creator.ts) constructs `obsidian://new` or `obsidian://daily`, with vault/path and append/prepend options. Normally content travels through the clipboard; legacy/fallback mode embeds it in the URI. It does not directly write into the vault. Obsidian must be installed and handle the URI; it need not already be running, but must launch/process the request. `silent=true` is not headless storage. Separately, [Save to Downloads](https://github.com/obsidianmd/obsidian-clipper/blob/6d56d618b00bd970aa738d6a7a61edee27783e81/src/core/popup.ts) downloads Markdown without Obsidian; this is not automatic delivery to the selected vault.

**Templates:** import/export JSON; choose note name, folder, properties and content; create, append/prepend existing notes, or append/prepend daily notes. URL/regex/schema.org triggers select templates. Variables include `{{title}}`, `{{url}}`, `{{content}}`, `{{selection}}`, dates, metadata, CSS selectors and JSON-LD; filters transform results. Properties become YAML frontmatter. [Templates](https://help.obsidian.md/web-clipper/templates), [variables](https://help.obsidian.md/web-clipper/variables).

**Capture:** defaults to main-article extraction; selection/highlights can replace it, and full-page HTML or selectors are available. Highlights can include text, images and blocks and persist for revisits. Images normally remain remote URLs; Obsidian's **Download attachments for current file** makes local copies afterward. Offline text does not imply offline images. [Capture](https://help.obsidian.md/web-clipper/capture), [highlighter](https://help.obsidian.md/web-clipper/highlight).

**Interpreter:** prompt variables such as `{{"Summarize this page"}}` run together against configurable page context; local Ollama and custom providers are supported. **Yes, WorkScribe can expose a compatible localhost endpoint**, but that remains untested. Set custom provider “WorkScribe,” full URL `http://127.0.0.1:PORT/v1/chat/completions`, a model ID, and a pairing token as API key. The [source](https://github.com/obsidianmd/obsidian-clipper/blob/6d56d618b00bd970aa738d6a7a61edee27783e81/src/utils/interpreter.ts) sends non-streaming `model`/`messages`, bearer authorization, and expects `choices[0].message.content` containing JSON `{"prompts_responses":{"prompt_1":"…"}}`. Bound context/output; use a generative model, not EmbeddingGemma alone. Allow the extension origin and required headers/preflight where applicable; verify browser local-network permissions. Keep this endpoint inference-only. [Interpreter docs](https://help.obsidian.md/web-clipper/interpreter).

## 2. Vault storage and native conventions

**Verified:** a vault is an ordinary folder; external editors are supported and Obsidian refreshes external changes. Direct file writes are therefore the simplest integration. [Storage](https://help.obsidian.md/Files+and+folders/How+Obsidian+stores+data).

**Proposed safety:** atomic same-directory replacement, serialized WorkScribe writes, stable IDs and content-hash checks before modifying existing notes. Atomic replacement alone does not prevent another editor's lost update. On conflict preserve both versions; never regenerate user edits blindly. Keep `.obsidian` untouched. Use one sync system: Obsidian warns that combining its Sync with another file-sync service can corrupt/duplicate files. For iCloud, handle placeholders/download failures and simultaneous edits; do not interpret unavailable files as deletions. Direct writes work while Obsidian is closed; Obsidian Sync itself requires the app to run. [Sync guidance](https://help.obsidian.md/sync/faq), [local/remote vaults](https://help.obsidian.md/Obsidian+Sync/Local+and+remote+vaults).

[URI](https://help.obsidian.md/Extending+Obsidian/Obsidian+URI) supports open/new/daily/search; use for navigation, not transactional writes. The community [Local REST API](https://github.com/coddingtonbear/obsidian-local-rest-api) reports authenticated HTTPS CRUD, section patches, active-note access and events. It requires Obsidian and the plugin running; keep it optional rather than a storage dependency.

**Proposed note:** `Meetings/2026-10-13 Planning.md`, with separate `People/Alex.md`:

```markdown
---
workscribe_id: meeting-<uuid>
type: meeting
date: 2026-10-13
attendees:
  - "[[People/Alex]]"
tags:
  - meeting
---
## Notes
Reviewed [[Clips/Launch research]].
## Actions
- [ ] [[People/Alex]]: Send forecast 📅 2026-10-16
```

Use flat YAML, ISO dates, quoted wikilinks, plural `tags`/`aliases`, and vault-relative paths to avoid ambiguous names. [Properties](https://help.obsidian.md/properties), [links](https://help.obsidian.md/links). The checkbox works natively; the due-date suffix follows [Tasks](https://github.com/obsidian-tasks-group/obsidian-tasks/blob/main/docs/Getting%20Started/Dates.md). [Dataview](https://blacksmithgu.github.io/obsidian-dataview/annotation/metadata-pages/) reads frontmatter; respect any configured Tasks filter. [Search](https://help.obsidian.md/plugins/search) supports paths, tags, properties and tasks; [Bases](https://help.obsidian.md/bases) provides property-driven views stored in `.base` files. Neither replaces WorkScribe's semantic/multimodal index.

## 3. Watching and indexing

**Proposed:** initial crawl plus FSEvents, debounce, hash-based upserts and stable-ID rename tracking. Persist event checkpoints; rescan on startup gaps, root moves or dropped/coalesced events, as [Apple requires](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html). Exclude configuration, caches and our own duplicate transcript exports.

Parse Markdown structurally: YAML; `[[path#heading|alias]]`; block references; `![[embeds]]`; standard links; `==highlights==`; `> [!note]` callouts; tasks and code fences. Preserve source spans and treat unknown syntax as text. Resolve embeds without recursive cycles; index local attachments separately. [Syntax](https://help.obsidian.md/syntax), [callouts](https://help.obsidian.md/callouts). Store URL, capture time, vault-relative path and content hash. Deep-link results with `obsidian://open?vault=VAULT&file=PATH`, percent-encoding each value; resolve current paths after renames.

## 4. When our Chrome extension earns its cost

**Proposed:** build it for “attach to current meeting,” “ask about this page,” or explicit live page sharing. Static Clipper templates can append to a named note, but do not know WorkScribe's active meeting/Ask state. Clipper already has [YouTube transcript/player handling](https://github.com/obsidianmd/obsidian-clipper/blob/6d56d618b00bd970aa738d6a7a61edee27783e81/src/utils/reader-transcript.ts); our advantage is timestamp-to-meeting association. PDF capture needs a separate path: pass the URL/downloaded file to WorkScribe's PDF importer; do not assume browser PDF-viewer DOM access.

Smallest MV3 design: toolbar/context-menu action; `activeTab`, `scripting`, `contextMenus`, `nativeMessaging`; extract URL/title/selection/readable text/video time; show destination; send a versioned request ID through service worker → signed native host → app. [Scripting](https://developer.chrome.com/docs/extensions/reference/api/scripting), [native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging). Explicitly selected live sharing needs renewed permissions across navigation.

Prefer native messaging's exact extension-ID allowlist and no listening port. Localhost HTTP is simpler for the Interpreter but needs loopback binding, pairing token, strict Origin/Host checks, size/rate limits and no arbitrary file/command APIs. Custom URLs suit launching/navigation, not bulk sensitive content or reliable acknowledgments. Treat page text as untrusted data; never let it issue app commands. [Chrome security guidance](https://developer.chrome.com/docs/extensions/develop/concepts/messaging#security-considerations).

## 5. Prior art and effort

**Reported, not run:** [Smart Connections](https://github.com/brianpetro/obsidian-smart-connections) supplies local semantic retrieval; [Copilot](https://github.com/logancyang/obsidian-copilot) layers local/cloud AI over vault files; [AI Meeting Notes](https://github.com/tsheil/obsidian_plugin_AI_meeting_notes) writes linked audio/transcript/summary notes. These are plugins, not proof of an independent native app integration. [Readwise](https://docs.readwise.io/readwise/docs/exporting-highlights/obsidian) uses customizable, append-only exports that preserve edits; [Omnivore's plugin](https://github.com/omnivore-app/obsidian-omnivore) imports articles/highlights. Borrow stable provenance and edit preservation, not service dependencies or another plugin's embedding cache.

**Estimates, one engineer, existing index/generation runtime assumed:** vault adapter/schema/templates/deep links: 3–5 days; watcher/parser/index integration and conflict/restart tests: 5–8; Interpreter endpoint: 2–3; optional Chrome/native-host MVP: 5–8; live navigation, video and PDF hardening: another 5–10. First useful vault + Clipper release: roughly two weeks; broader browser integration: four–six weeks. Acceptance gates: Obsidian closed/open, simultaneous edits, rename/delete, sync placeholders, duplicate clips, restart recovery, local inference and zero unintended cloud calls.
