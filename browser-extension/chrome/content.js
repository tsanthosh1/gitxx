// GitHub follows most of its own links without a real navigation (Turbo), so the redirect rule never sees them.
// Clicks on links GitXX can show are sent to GitXX here instead. Modified clicks and target=_blank links open a
// new tab, which the redirect rule handles.
(async () => {
  const rules = await import(chrome.runtime.getURL("rules.js"));
  const { exempt } = await chrome.runtime.sendMessage({ type: "is-exempt" });
  if (exempt) return;
  let settings = await rules.loadSettings();
  chrome.storage.onChanged.addListener(async (_changes, area) => {
    if (area === "sync") settings = await rules.loadSettings();
  });

  window.addEventListener("click", (event) => {
    if (!settings.enabled || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const anchor = event.composedPath().find((el) => el instanceof HTMLAnchorElement && el.href);
    if (!anchor || anchor.hasAttribute("download") || (anchor.target && anchor.target !== "_self")) return;
    const url = new URL(anchor.href);
    const here = new URL(location.href);
    if (url.origin === here.origin && url.pathname === here.pathname && url.search === here.search) return;
    if (!rules.gitxxTarget(url.href, settings)) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    chrome.runtime.sendMessage({ type: "send-to-gitxx", url: url.href }).then((reply) => {
      if (!reply?.ok) location.assign(url.href);
    });
  }, true);
})();
