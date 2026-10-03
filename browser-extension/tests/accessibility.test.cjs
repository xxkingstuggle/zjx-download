const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const options = fs.readFileSync(path.join(root, "src/optionsui/OptionUi.tsx"), "utf8");
const popup = fs.readFileSync(path.join(root, "src/browseractionpopup/BrowserAction.tsx"), "utf8");
const selection = fs.readFileSync(path.join(root, "src/popup/selection/SelectionPopup.ts"), "utf8");
const media = fs.readFileSync(path.join(root, "src/popup/media/MediaSelectionPopup.ts"), "utf8");

for (const key of [
  "config_show_popups",
  "config_silent_add_download",
  "config_silent_start_download",
  "config_auto_capture_links",
  "config_send_cookies",
  "config_close_captured_tab",
]) {
  assert.match(options, new RegExp(`aria-label=\\{browser\\.i18n\\.getMessage\\("${key}"\\)\\}`), `${key} checkbox needs an accessible name`);
}
assert.match(options, /aria-label=\{title\}/, "browser fallback checkbox needs an accessible name");
assert.match(options, /disabled=\{!props\.silentAddEnabled\}/, "silent start must expose its dependency through native disabled state");
assert.match(options, /role="status"[\s\S]*aria-live="polite"/, "connection test feedback must be announced");
assert.doesNotMatch(options, /\balert\s*\(/, "connection errors must stay inline instead of using blocking alerts");
assert.match(popup, /aria-label=\{props\.title\}/, "quick settings toggles need accessible names");
assert.match(popup, /role="status"\s+aria-live="polite"/, "popup connection status must be announced");
assert.match(selection, /closeButton\.setAttribute\("aria-label", closeLabel\)/, "selection popup close action needs a name");
assert.match(media, /toggle\.setAttribute\("aria-expanded"/, "media picker must expose its expanded state");
assert.match(media, /button\.type = "button"/, "media rows must be keyboard-operable buttons");

console.log("Extension controls expose names, connection feedback, and state to assistive technology");
