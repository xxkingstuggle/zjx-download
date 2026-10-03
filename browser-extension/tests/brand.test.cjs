const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
const messages = JSON.parse(fs.readFileSync(path.join(root, "public/_locales/en/messages.json"), "utf8"));
const messagesZh = JSON.parse(fs.readFileSync(path.join(root, "public/_locales/zh_CN/messages.json"), "utf8"));
const readme = fs.readFileSync(path.join(root, "README.md"), "utf8");
const thirdPartyNotices = fs.readFileSync(path.join(root, "public/THIRD_PARTY_NOTICES.txt"), "utf8");

assert.equal(pkg.name, "zjx-download-chrome-extension");
assert.equal(pkg.displayName, "zjx-download");
assert.equal(pkg.shortName, "zjx-download");
assert.equal(pkg.repository, "https://github.com/xxkingstuggle/zjx-download");
assert.equal(pkg.author, "AmirHossein Abdolmotallebi", "keep the original author attribution");

for (const key of [
  "extension_name",
  "extension_short_name",
  "extension_description",
  "context_menu_download_with_abdm",
  "context_menu_download_selected_links_with_abdm",
  "option_ui_title",
  "browser_action_popup_title",
  "connection_error_api_error",
  "connection_error_network_error",
  "config_fallback_to_browser",
  "config_fallback_to_browser_description",
  "abdm_notification_title",
  "abdm_notification_download_captured_silently",
  "download_media_title",
]) {
  assert.ok(messages[key]?.message, `missing localized brand surface: ${key}`);
  assert.match(messages[key].message, /zjx-download/i, `${key} should show the product brand`);
}

const visibleMessages = Object.values(messages).map(({ message }) => message).join("\n");
assert.doesNotMatch(visibleMessages, /AB Download Manager|AB DM|ABDM/i);
assert.deepEqual(Object.keys(messagesZh).sort(), Object.keys(messages).sort(), "English and Chinese locales must cover the same UI strings");
for (const [key, message] of Object.entries(messagesZh)) {
  assert.ok(message.message.trim(), `empty Chinese translation: ${key}`);
  assert.doesNotMatch(message.message, /AB Download Manager|AB DM/i, `${key} still exposes the upstream product name`);
}

const localizedRoot = path.resolve(root, "../Sources/ABDownloadManagerApp/Resources");
for (const locale of fs.readdirSync(localizedRoot).filter((entry) => entry.endsWith(".lproj"))) {
  const stringsPath = path.join(localizedRoot, locale, "Localizable.strings");
  if (!fs.existsSync(stringsPath)) continue;
  const strings = fs.readFileSync(stringsPath, "utf8");
  const acknowledgement = strings.match(/^\s*"menu\.acknowledgements"\s*=\s*"([^"]*(?:\\.[^"]*)*)"\s*;/m)?.[1];
  assert.ok(acknowledgement?.includes("zjx-download"), `${locale} acknowledgement must lead with the current brand`);
  assert.match(acknowledgement, /AB Download Manager|AmirHossein Abdolmotallebi/, `${locale} acknowledgement must preserve legal origin attribution`);
  const nonLegalStrings = strings.replace(/^\s*"menu\.acknowledgements"\s*=\s*"(?:\\.|[^"])*"\s*;\s*$/gm, "");
  assert.doesNotMatch(nonLegalStrings, /AB Download Manager|AB DM/i, `${locale} exposes the upstream brand outside legal attribution`);
}

assert.match(readme, /zjx-download for Chrome/);
assert.match(readme, /1871203ce9665ea6802e8d1328f8b70c7dc9d948/);
assert.match(readme, /Apache-2\.0 license and attribution are retained/);
assert.match(readme, /github\.com\/xxkingstuggle\/zjx-download\/issues/);
assert.match(thirdPartyNotices, /Generated from package-lock\.json for 23 production dependency package instances\./);
assert.match(thirdPartyNotices, /## react-dom /);
assert.match(thirdPartyNotices, /Declared license: MIT/);

for (const size of [16, 32, 48, 96, 128]) {
  const icon = fs.readFileSync(path.join(root, `public/icons/icon-${size}.png`));
  assert.equal(icon.readUInt32BE(16), size, `icon-${size}.png width`);
  assert.equal(icon.readUInt32BE(20), size, `icon-${size}.png height`);
}

console.log("Chrome brand, visible strings, attribution, links, and icon sizes passed");
