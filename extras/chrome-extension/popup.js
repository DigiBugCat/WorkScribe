// The popup: read the page (on this click only), show where it will go, send on a second click.
import { capture, describe, send } from "./shared.js";

const $ = (id) => document.getElementById(id);
let page = null, status = null;

async function load() {
  const pending = await chrome.runtime.sendMessage({ type: "pending" }).catch(() => null);
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (pending?.mode === "ask") $("question").focus();
  try {
    [page, status] = await Promise.all([capture(pending?.tabId ?? tab.id), send("status")]);
  } catch (error) {
    $("title").textContent = "Can't read this page";
    $("what").textContent = String(error.message || error);
    $("destination").textContent = "";
    return;
  }
  $("title").textContent = page.title;
  $("what").textContent = page.selection ? `Selection · ${page.selection.length.toLocaleString()} characters`
    : `Page text · ${(page.text || "").length.toLocaleString()} characters`
      + (page.videoTime != null ? ` · video at ${Math.floor(page.videoTime / 60)}:${String(page.videoTime % 60).padStart(2, "0")}` : "");
  if (!status.ok) {
    $("destination").textContent = status.error || "WorkScribe isn't reachable.";
    return;
  }
  $("destination").textContent = `${describe(status.destination)} · ${status.vault ?? ""}`;
  $("clip").disabled = false; $("ask").disabled = false;
}

async function submit(type) {
  $("clip").disabled = true; $("ask").disabled = true;
  $("result").textContent = "Sending…";
  const extra = { page, meetingId: status.destination?.meetingId };
  const question = $("question").value.trim();
  if (type === "ask" && question) extra.question = question.slice(0, 4000);
  const response = await send(type, extra);
  $("result").textContent = response.ok
    ? (type === "ask" ? "Sent to WorkScribe. Open it to see the answer." : `Saved · ${describe(response.destination)}`)
    : (response.error || "Couldn't send.");
  if (response.ok) setTimeout(() => window.close(), 1400);
  else { $("clip").disabled = false; $("ask").disabled = false; }
}

$("clip").addEventListener("click", () => submit("clip"));
$("ask").addEventListener("click", () => submit("ask"));
load();
