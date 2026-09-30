import { gitxxURL, withSkip } from "./rules.js";

// The redirect rule appends the original URL raw (`?to=https://github.com/…`); manual opens encode it.
const raw = location.href.slice(location.href.indexOf("?to=") + 4);
const link = raw.startsWith("https%3A") ? decodeURIComponent(raw) : raw;

async function leave() {
  if (history.length > 1) {
    history.back();
    return;
  }
  const tab = await chrome.tabs.getCurrent();
  if (tab?.id !== undefined) chrome.tabs.remove(tab.id);
}

// Without GitXX's link helper the link goes through gitxx://, which makes Chrome ask "Open GitXX?". That prompt
// takes focus from the page, so this tab can't tell it from GitXX taking over and stays until closed.
function showFallback() {
  document.getElementById("target").textContent = link;
  document.body.hidden = false;
  document.getElementById("retry").addEventListener("click", () => { location.href = gitxxURL(link); });
  document.getElementById("browser").addEventListener("click", () => location.replace(withSkip(link)));
  document.getElementById("close").addEventListener("click", leave);
  location.href = gitxxURL(link);
}

try {
  const reply = await chrome.runtime.sendNativeMessage("com.gitxx.links", { url: link });
  if (reply?.ok) leave(); else showFallback();
} catch {
  showFallback();
}
