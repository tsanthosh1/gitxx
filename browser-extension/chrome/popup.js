import { loadSettings } from "./rules.js";

const settings = await loadSettings();
const enabled = document.getElementById("enabled");
enabled.checked = settings.enabled;
enabled.addEventListener("change", () => chrome.storage.sync.set({ enabled: enabled.checked }));

const owners = document.getElementById("owners");
owners.value = settings.owners;
owners.addEventListener("change", () => chrome.storage.sync.set({ owners: owners.value.trim() }));

const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
const openHere = document.getElementById("open-here");
const onGitHub = /^https:\/\/(www\.)?github\.com\/[^/]+\/[^/]+/.test(tab?.url || "");
openHere.disabled = !onGitHub;
openHere.title = onGitHub ? "" : "Open a github.com repository page first";
openHere.addEventListener("click", async () => {
  await chrome.runtime.sendMessage({ type: "open-in-gitxx", tabId: tab.id, url: tab.url });
  window.close();
});
