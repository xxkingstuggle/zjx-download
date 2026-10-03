import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const requestedTargets = process.argv[2] ?? "all";
const targets = requestedTargets === "all" ? ["chrome", "firefox"] : [requestedTargets];
const supportedTargets = new Set(["chrome", "firefox"]);

if (targets.some((target) => !supportedTargets.has(target))) {
  console.error(`Unsupported target '${requestedTargets}'. Use chrome, firefox, or all.`);
  process.exit(2);
}

function addStringPaths(value, label, found) {
  if (typeof value === "string") found.push({ path: value, label });
  else if (Array.isArray(value)) value.forEach((item, index) => addStringPaths(item, `${label}[${index}]`, found));
  else if (value && typeof value === "object") {
    Object.entries(value).forEach(([key, item]) => addStringPaths(item, `${label}.${key}`, found));
  }
}

function manifestPaths(manifest) {
  const found = [];
  addStringPaths(manifest.icons, "icons", found);
  addStringPaths(manifest.content_scripts?.map(({ js, css }) => ({ js, css })), "content_scripts", found);
  addStringPaths(manifest.options_ui?.page, "options_ui.page", found);
  addStringPaths(manifest.options_page, "options_page", found);
  addStringPaths(manifest.browser_action?.default_popup, "browser_action.default_popup", found);
  addStringPaths(manifest.action?.default_popup, "action.default_popup", found);
  addStringPaths(manifest.page_action?.default_popup, "page_action.default_popup", found);
  addStringPaths(manifest.background?.page, "background.page", found);
  addStringPaths(manifest.background?.scripts, "background.scripts", found);
  addStringPaths(manifest.background?.service_worker, "background.service_worker", found);
  addStringPaths(manifest.devtools_page, "devtools_page", found);
  addStringPaths(manifest.chrome_url_overrides, "chrome_url_overrides", found);
  addStringPaths(manifest.sandbox?.pages, "sandbox.pages", found);
  addStringPaths(manifest.side_panel?.default_path, "side_panel.default_path", found);
  addStringPaths(manifest.web_accessible_resources?.flatMap((entry) =>
    typeof entry === "string" ? [entry] : (entry.resources ?? [])), "web_accessible_resources", found);
  return found;
}

function matchesPattern(base, pattern) {
  if (pattern.includes("*") || pattern.includes("?")) {
    const escaped = pattern.split("").map((char) => {
      if (char === "*") return ".*";
      if (char === "?") return ".";
      return char.replace(/[|\\{}()[\]^$+?.]/g, "\\$&");
    }).join("");
    const regex = new RegExp(`^${escaped}$`);
    return fs.existsSync(base) && fs.readdirSync(path.dirname(base)).some((name) => regex.test(name));
  }
  return fs.existsSync(base);
}

let failures = 0;
for (const target of targets) {
  const dist = path.join(root, "dist", target);
  if (target === "chrome" && !fs.existsSync(path.join(dist, "THIRD_PARTY_NOTICES.txt"))) {
    console.error(`[${target}] missing THIRD_PARTY_NOTICES.txt`);
    failures++;
  }
  const manifestPath = path.join(dist, "manifest.json");
  if (!fs.existsSync(manifestPath)) {
    console.error(`[${target}] missing ${path.relative(root, manifestPath)}`);
    failures++;
    continue;
  }

  let manifest;
  try {
    manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  } catch (error) {
    console.error(`[${target}] invalid manifest.json: ${error.message}`);
    failures++;
    continue;
  }

  const references = manifestPaths(manifest);
  let targetFailures = 0;
  for (const reference of references) {
    const resolved = path.resolve(dist, reference.path);
    if (!resolved.startsWith(`${dist}${path.sep}`) && resolved !== dist) {
      console.error(`[${target}] ${reference.label} escapes dist: ${reference.path}`);
      targetFailures++;
    } else if (!matchesPattern(resolved, reference.path)) {
      console.error(`[${target}] ${reference.label} references missing file: ${reference.path}`);
      targetFailures++;
    }
  }
  if (targetFailures === 0) console.log(`[${target}] OK (${references.length} manifest file references checked)`);
  failures += targetFailures;
}

if (failures > 0) process.exit(1);
