// Context menu entries. Each opens the popup so the user sees the destination before anything is sent;
// if the browser can't open it, the clip is sent directly and the badge reports where it went.
import { capture, send } from "./shared.js";

let pending = null; // { mode, tabId } handed to the popup

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({ id: "clip", title: "Clip to current meeting", contexts: ["page", "selection", "link", "video"] });
  chrome.contextMenus.create({ id: "ask", title: "Ask WorkScribe about this page", contexts: ["page", "selection", "link", "video"] });
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (!tab?.id) return;
  pending = { mode: info.menuItemId, tabId: tab.id };
  try {
    await chrome.action.openPopup();
  } catch {
    // Older Chrome: no popup from a menu. Clip directly (asks need the popup's question box).
    if (info.menuItemId !== "clip") return;
    pending = null;
    try {
      const status = await send("status");
      const page = await capture(tab.id);
      const response = await send("clip", { page, meetingId: status.destination?.meetingId });
      badge(tab.id, response.ok ? "✓" : "!", response.ok
        ? `Clipped to ${response.destination?.kind === "meeting" ? response.destination.title : "Inbox"}` : response.error);
    } catch (error) {
      badge(tab.id, "!", String(error.message || error));
    }
  }
});

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (sender.id !== chrome.runtime.id || message?.type !== "pending") return;
  reply(pending);
  pending = null;
});

function badge(tabId, text, title) {
  chrome.action.setBadgeText({ tabId, text });
  chrome.action.setTitle({ tabId, title: title || "WorkScribe" });
}
