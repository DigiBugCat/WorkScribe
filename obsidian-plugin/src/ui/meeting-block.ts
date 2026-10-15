// User lines stay verbatim, with live AI text underneath and temporary evidence.

import { MarkdownRenderChild } from "obsidian";
import { clock, duration, meetingUrl, parseBlockId } from "../lib/format";
import type WorkScribePlugin from "../main";
import { openExternal } from "./render";

export function registerMeetingBlock(plugin: WorkScribePlugin): void {
  plugin.registerMarkdownCodeBlockProcessor("workscribe-meeting", (source, el, ctx) => {
    const id = parseBlockId(source);
    const card = el.createDiv({ cls: "ws-meeting-card" });
    if (!id) {
      card.createDiv({ cls: "ws-warn", text: "workscribe-meeting: add id=<meeting id>" });
      return;
    }
    card.createDiv({ cls: "ws-mc-meta", text: "Loading meeting…" });
    const child = new MarkdownRenderChild(card);
    ctx.addChild(child);
    void plugin.client.meeting(id).then(
      (m) => {
        card.empty();
        const head = card.createDiv({ cls: "ws-mc-head" });
        const a = head.createEl("a", { cls: "ws-mc-title", text: m.title, href: meetingUrl(m.id) });
        a.addEventListener("click", (e) => {
          e.preventDefault();
          openExternal(meetingUrl(m.id));
        });
        const when = m.startedAt ? window.moment(m.startedAt).format("ddd D MMM · HH:mm") : "";
        head.createDiv({ cls: "ws-mc-meta", text: [when, duration(m.duration), m.speakers.join(", ")].filter(Boolean).join(" · ") });
        if (m.brief) card.createDiv({ cls: "ws-mc-brief", text: m.brief });
        // Your lines, with the text you accepted merged in. Pending suggestions stay in the meeting view.
        const notes = m.notes;
        if (notes.length) {
          const ul = card.createEl("ul", { cls: "ws-mc-notes" });
          for (const n of notes.slice(0, 8)) {
            const li = ul.createEl("li");
            li.setText(n.text);
            if (n.enhanced) li.createDiv({ cls: "ws-sugg", text: `${n.enhanced.topic} ${n.enhanced.text}`.trim() });
          }
        }
        if (m.retention === "purged" && m.obsidianLink) card.createEl("a", { href: m.obsidianLink, text: "Open vault note" });

        if (m.actionItems.length) {
          card.createDiv({ cls: "ws-mc-sub", text: "Action items" });
          const ul = card.createEl("ul", { cls: "ws-mc-actions" });
          for (const it of m.actionItems) {
            const li = ul.createEl("li");
            li.createSpan({ cls: "ws-mc-owner", text: it.owner.split(" ")[0]! });
            li.appendText(" " + it.text);
            if (it.at !== undefined) {
              const t = li.createEl("a", { cls: "ws-mc-time", text: clock(it.at), href: meetingUrl(m.id, it.at) });
              t.addEventListener("click", (e) => {
                e.preventDefault();
                openExternal(meetingUrl(m.id, it.at));
              });
            }
          }
        }
      },
      (e: unknown) => {
        card.empty();
        card.createDiv({ cls: "ws-warn", text: `Couldn't load meeting ${id}: ${e instanceof Error ? e.message : String(e)}` });
      },
    );
  });
}
