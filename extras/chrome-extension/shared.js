// Shared by the popup and the service worker. Nothing here runs on a page until the user clicks.
export const HOST = "com.workscribe.clipper";
const LIMITS = { title: 1000, selection: 200000, text: 1000000, description: 4000, author: 300, site: 200 };

// Injected into the active tab with chrome.scripting (activeTab grants it for the clicked tab only).
// Must be self-contained: it is serialized and run in the page's isolated world. Reads, never modifies the page.
export function extractPage() {
  const meta = (selector) => document.querySelector(selector)?.getAttribute("content")?.trim() || null;
  const selection = String(window.getSelection?.() ?? "").trim() || null;

  // Readability-style: drop chrome, then pick the container holding the most paragraph text.
  const root = document.querySelector("article, main, [role=main]") || document.body;
  const clone = root.cloneNode(true);
  clone.querySelectorAll("script, style, noscript, svg, iframe, nav, header, footer, aside, form, button, [aria-hidden=true], [hidden]")
    .forEach((node) => node.remove());
  const scores = new Map();
  clone.querySelectorAll("p, li, pre, blockquote, h1, h2, h3, td").forEach((node) => {
    const length = (node.textContent || "").trim().length;
    if (length < 25 || !node.parentElement) return;
    scores.set(node.parentElement, (scores.get(node.parentElement) || 0) + length);
  });
  let best = clone, bestScore = 0;
  for (const [node, score] of scores) if (score > bestScore) { best = node; bestScore = score; }
  // A container with most of the text, not a single list of links.
  if (bestScore < 500) best = clone;
  const text = (best.innerText || best.textContent || "").replace(/\n{3,}/g, "\n\n").trim();

  let videoTime = null;
  if (/(^|\.)youtube\.com$/.test(location.hostname)) {
    const video = document.querySelector("video");
    if (video && Number.isFinite(video.currentTime)) videoTime = Math.floor(video.currentTime);
  }
  return {
    url: location.href,
    title: document.title || meta('meta[property="og:title"]') || location.href,
    site: meta('meta[property="og:site_name"]'),
    selection,
    text: text || null,
    description: meta('meta[name="description"]') || meta('meta[property="og:description"]'),
    author: meta('meta[name="author"]'),
    videoTime,
  };
}

/** Runs extractPage in a tab and trims the result to the host's limits. */
export async function capture(tabId) {
  const [result] = await chrome.scripting.executeScript({ target: { tabId }, func: extractPage });
  const page = result?.result;
  if (!page) throw new Error("This page can't be read (browser pages and the Web Store are off limits).");
  if (page.videoTime != null) {
    const url = new URL(page.url);
    url.searchParams.set("t", `${page.videoTime}s`);
    page.url = url.toString();
  }
  for (const [key, limit] of Object.entries(LIMITS)) {
    if (typeof page[key] === "string" && page[key].length > limit) page[key] = page[key].slice(0, limit);
  }
  for (const key of Object.keys(page)) if (page[key] === null) delete page[key];
  return page;
}

/** One request through the native host; resolves with the app's response. */
export function send(type, extra = {}) {
  const message = { v: 1, id: crypto.randomUUID(), type, ...extra };
  return new Promise((resolve) => {
    chrome.runtime.sendNativeMessage(HOST, message, (response) => {
      if (chrome.runtime.lastError || !response) {
        resolve({ ok: false, code: "no_host",
          error: "WorkScribe's browser helper isn't installed. Run install-native-host.sh (see README)." });
      } else resolve(response);
    });
  });
}

export function describe(destination) {
  if (!destination) return "";
  return destination.kind === "meeting" ? `Meeting: ${destination.title}` : "No meeting recording — saved to Inbox";
}
