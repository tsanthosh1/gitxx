// Which github.com links GitXX opens: every page GitXX has a view for (mirrors GitHubURLTarget.parse in the app).
// Branch links stay in the browser because opening them in GitXX checks the branch out.

// Added by GitXX to links it sends to the browser ("Open in browser", repos not on this Mac), so they stay here.
export const SKIP_PARAM = "gitxx_browser";

export const DEFAULT_SETTINGS = {
  enabled: true,
  owners: "", // comma-separated; empty = any owner
};

// First path segments that are GitHub pages, not owners.
const RESERVED = [
  "settings", "orgs", "organizations", "notifications", "marketplace", "login", "logout", "join", "session",
  "sessions", "signup", "password_reset", "auth", "oauth", "explore", "topics", "trending", "collections",
  "sponsors", "features", "pricing", "enterprise", "about", "search", "pulls", "issues", "codespaces", "new",
  "dashboard", "apps", "account", "site", "security", "customer-stories", "readme", "team", "copilot",
  "github-copilot", "users", "stars", "watching", "contact", "home", "discussions",
];
const RESERVED_SET = new Set(RESERVED);

function ownerList(settings) {
  return (settings.owners || "").split(",").map((o) => o.trim().toLowerCase()).filter((o) => /^[a-z0-9-]+$/.test(o));
}

/** Returns a short description ("PR #42 in owner/repo") when GitXX should open `raw`, else null. */
export function gitxxTarget(raw, settings) {
  let url;
  try { url = new URL(raw); } catch { return null; }
  if (url.protocol !== "https:" || !["github.com", "www.github.com"].includes(url.hostname)) return null;
  if (url.searchParams.has(SKIP_PARAM)) return null;
  const parts = url.pathname.split("/").filter(Boolean);
  if (parts.length < 2 || RESERVED_SET.has(parts[0].toLowerCase())) return null;
  const [owner, repo, section, ...rest] = parts;
  const owners = ownerList(settings);
  if (owners.length && !owners.includes(owner.toLowerCase())) return null;
  const slug = `${owner}/${repo}`;

  if (section === undefined) return slug;
  if (section === "pulls") return `Pull requests in ${slug}`;
  if (section === "pull" && /^\d+$/.test(rest[0] || "")) return `PR #${rest[0]} in ${slug}`;
  if (section === "commit" && /^[0-9a-f]+$/i.test(rest[0] || "")) return `Commit ${rest[0].slice(0, 7)} in ${slug}`;
  if (section === "actions") return `Actions in ${slug}`;
  return null;
}

/** The same match as `gitxxTarget`, as RE2 for declarativeNetRequest (reserved owners and SKIP_PARAM are
 *  excluded by separate allow rules). */
export function redirectRegex(settings) {
  const owners = ownerList(settings);
  const owner = owners.length ? `(?:${owners.join("|")})` : "[^/?#]+";
  const page = "(?:/?|/pulls(?:/[^?#]*)?|/pull/[0-9]+(?:/[^?#]*)?|/commit/[0-9a-fA-F]+(?:/[^?#]*)?|/actions(?:/[^?#]*)?)";
  return `^https://(?:www\\.)?github\\.com/${owner}/[^/?#]+${page}(?:[?#].*)?$`;
}

/** declarativeNetRequest urlFilters for the reserved first segments (one regex for all of them is over
 *  Chrome's 2 KB compiled-regex limit). `^` matches a separator or the end of the URL. */
export const reservedFilters = RESERVED.map((segment) => `||github.com/${segment}^`);
export const skipRegex = `[?&]${SKIP_PARAM}=`;

export async function loadSettings() {
  const stored = await chrome.storage.sync.get(DEFAULT_SETTINGS);
  return { ...DEFAULT_SETTINGS, ...stored };
}

export function gitxxURL(link) {
  return "gitxx://open?url=" + encodeURIComponent(link);
}

export function withSkip(link) {
  const url = new URL(link);
  url.searchParams.set(SKIP_PARAM, "1");
  return url.toString();
}
