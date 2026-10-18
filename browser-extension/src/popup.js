import {saveExtensionSettings} from "./app-api.js";
import {ping} from "./app-api.js";
import {saveConfig} from "./storage.js";
const config = await chrome.runtime.sendMessage({type: "zjx-config"}).catch(async () => null) || {};
for (const key of ["autoCapture", "showPageWidgets", "silentAdd"]) { const input = document.getElementById(key); input.checked = Boolean(config[key]); input.addEventListener("change", async () => { const patch = {[key]: input.checked}; if ((key === "autoCapture" || key === "showPageWidgets") && input.checked && !await requestCapturePermissions()) { input.checked = false; return; } const {synced} = await saveExtensionSettings(patch); document.getElementById("message").textContent = synced ? "设置已同步到 App。" : "Chrome 已保存；App 尚未确认同步。"; }); }
const status = await ping(); document.getElementById("connection").textContent = status.connected ? `已连接 · ${status.channel}` : "App 未连接";
document.getElementById("settings").addEventListener("click", () => chrome.runtime.openOptionsPage());
document.getElementById("pageMedia").addEventListener("click", async () => {
  const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
  if (tab?.id != null) await chrome.runtime.sendMessage({type:"zjx-show-candidates", tabId: tab.id});
});
async function requestCapturePermissions() { const permissions = ["webRequest"]; const origins = ["http://*/*", "https://*/*"]; const granted = await chrome.permissions.request({permissions, origins}); if (!granted) { document.getElementById("message").textContent = "需要网站访问和 webRequest 权限才能发现媒体或自动接管。"; return false; } await saveConfig({siteAccessGranted: true}); return true; }
