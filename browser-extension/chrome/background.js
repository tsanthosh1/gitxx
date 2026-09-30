import { gitxxURL, loadSettings, redirectRegex, reservedFilters, skipRegex, SKIP_PARAM } from "./rules.js";

// Every navigation to a GitHub page GitXX can show goes to GitXX, whatever started it. Chrome redirects the
// request to redirect.html before it is sent (declarativeNetRequest), so GitHub never loads; that page hands the
// link to GitXX and steps back out of the tab. In-page clicks that GitHub handles without a navigation are
// caught by content.js.
//
// Staying in the browser: links GitXX opens there carry `gitxx_browser=1`, and the tab they open in keeps
// browsing GitHub normally until it is closed.

const RULE = { REDIRECT: 1, SKIP: 2, EXEMPT_TABS: 3, RESERVED: 100 };
const EXEMPT_KEY = "exemptTabs";

async function exemptTabs() {
  return (await chrome.storage.session.get({ [EXEMPT_KEY]: [] }))[EXEMPT_KEY];
}

// Serialized: overlapping updates would each remove the same old rules and then collide adding new ones.
let ruleUpdate = Promise.resolve();
function syncRules() {
  ruleUpdate = ruleUpdate.then(applyRules).catch((error) => console.error("GitXX Links: rules not applied", error));
  return ruleUpdate;
}

async function applyRules() {
  const settings = await loadSettings();
  const tabIds = await exemptTabs();
  const redirectPage = chrome.runtime.getURL("redirect.html");
  const main = { resourceTypes: ["main_frame"], requestMethods: ["get"] };
  const rules = [
    { id: RULE.SKIP, priority: 3, action: { type: "allow" }, condition: { ...main, regexFilter: skipRegex } },
    ...reservedFilters.map((urlFilter, i) => ({
      id: RULE.RESERVED + i, priority: 3, action: { type: "allow" }, condition: { ...main, urlFilter },
    })),
  ];
  if (tabIds.length) {
    rules.push({ id: RULE.EXEMPT_TABS, priority: 3, action: { type: "allow" }, condition: { ...main, tabIds } });
  }
  if (settings.enabled) {
    rules.push({
      id: RULE.REDIRECT, priority: 1,
      action: { type: "redirect", redirect: { regexSubstitution: `${redirectPage}?to=\\0` } },
      condition: { ...main, regexFilter: redirectRegex(settings), isUrlFilterCaseSensitive: false },
    });
  }
  const existing = await chrome.declarativeNetRequest.getSessionRules();
  await chrome.declarativeNetRequest.updateSessionRules({ removeRuleIds: existing.map((r) => r.id), addRules: rules });
}

async function setExempt(tabId, exempt) {
  const tabs = new Set(await exemptTabs());
  if (exempt === tabs.has(tabId)) return;
  if (exempt) tabs.add(tabId); else tabs.delete(tabId);
  await chrome.storage.session.set({ [EXEMPT_KEY]: [...tabs] });
  await syncRules();
}

syncRules();
chrome.runtime.onStartup.addListener(syncRules);
chrome.storage.onChanged.addListener((_changes, area) => { if (area === "sync") syncRules(); });

chrome.webNavigation.onCommitted.addListener((details) => {
  if (details.frameId === 0 && new URL(details.url).searchParams.has(SKIP_PARAM)) setExempt(details.tabId, true);
}, { url: [{ hostEquals: "github.com" }, { hostEquals: "www.github.com" }] });

chrome.tabs.onRemoved.addListener((tabId) => setExempt(tabId, false));

// GitXX installs a native messaging host, which opens links without Chrome's "Open GitXX?" prompt. Without it
// (not installed yet, or another browser profile) links fall back to the gitxx:// hand-off page.
const NATIVE_HOST = "com.gitxx.links";

async function sendToGitXX(link) {
  try {
    const reply = await chrome.runtime.sendNativeMessage(NATIVE_HOST, { url: link });
    return reply?.ok === true;
  } catch {
    return false;
  }
}

// Manual routes, whatever the settings say.
chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({ id: "open-link", title: "Open Link in GitXX", contexts: ["link"],
    targetUrlPatterns: ["https://github.com/*", "https://www.github.com/*"] });
  chrome.contextMenus.create({ id: "open-page", title: "Open Page in GitXX", contexts: ["page"],
    documentUrlPatterns: ["https://github.com/*", "https://www.github.com/*"] });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  const link = info.menuItemId === "open-link" ? info.linkUrl : info.pageUrl;
  if (link && tab?.id !== undefined) openInGitXX(tab.id, link);
});

chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message?.type === "open-in-gitxx" && message.tabId !== undefined) {
    openInGitXX(message.tabId, message.url);
    reply({ ok: true });
  } else if (message?.type === "send-to-gitxx") {
    sendToGitXX(message.url).then((ok) => reply({ ok }));
    return true;
  } else if (message?.type === "is-exempt") {
    exemptTabs().then((tabs) => reply({ exempt: tabs.includes(sender.tab?.id) }));
    return true;
  }
});

// Hands the link to GitXX from the current tab without leaving the page.
async function openInGitXX(tabId, link) {
  if (await sendToGitXX(link)) return;
  chrome.scripting.executeScript({
    target: { tabId },
    func: (target) => { window.location.href = target; },
    args: [gitxxURL(link)],
  }).catch(() => chrome.tabs.create({ url: chrome.runtime.getURL("redirect.html") + "?to=" + encodeURIComponent(link) }));
}
