import {getConfig, saveConfig, validPort} from "./storage.js";
import {fetchExtensionSettings, ping, saveExtensionSettings} from "./app-api.js";
const fields = ["port", "apiKey", "autoCapture", "minimumSizeKB", "extensions", "ignoredPatterns", "closeCapturedTab", "showPageWidgets", "sendRequestHeaders", "bypassKey", "silentAdd", "silentStart"];
const remote = await fetchExtensionSettings();
if (remote) {
  const {apiPort, ...preferences} = remote;
  await saveConfig({...preferences, ...(Number.isInteger(apiPort) ? {port: apiPort} : {})});
}
const config = await getConfig();
function render(value) { for (const id of fields) { const element = document.getElementById(id); if (id === "extensions" || id === "ignoredPatterns") element.value = (value[id === "extensions" ? id : id] || []).join(id === "extensions" ? ", " : "\n"); else element.value = value[id] ?? ""; if (element.type === "checkbox") element.checked = Boolean(value[id]); } }
render(config);
document.getElementById("save").addEventListener("click", async () => {
  const port = Number(document.getElementById("port").value);
  if (!validPort(port)) return show("端口必须为 1024–65535。", true);
  const patch = {};
  for (const id of fields) { const element = document.getElementById(id); if (element.type === "checkbox") patch[id] = element.checked; else if (id === "port" || id === "minimumSizeKB") patch[id] = Number(element.value); else if (id === "extensions") patch[id] = element.value.split(/[ ,]+/).map(value => value.replace(/^\./, "").toLowerCase()).filter(Boolean); else if (id === "ignoredPatterns") patch[id] = element.value.split(/\r?\n/).map(value => value.trim()).filter(Boolean); else patch[id] = element.value; }
  if (!patch.silentAdd) patch.silentStart = false;
  const needsSiteAccess = patch.autoCapture || patch.showPageWidgets;
  const requestedPermissions = [...(needsSiteAccess || patch.sendRequestHeaders ? ["webRequest"] : []), ...(patch.sendRequestHeaders ? ["cookies"] : [])];
  const requestedOrigins = needsSiteAccess || patch.sendRequestHeaders ? ["http://*/*", "https://*/*"] : [];
  if (requestedPermissions.length || requestedOrigins.length) {
    const granted = await chrome.permissions.request({permissions: requestedPermissions, origins: requestedOrigins});
    if (patch.sendRequestHeaders && !granted) return show("未获得请求头权限；设置未保存。", true);
    patch.siteAccessGranted = Boolean(granted && needsSiteAccess);
    if (needsSiteAccess && !granted) {
      patch.autoCapture = false;
      patch.showPageWidgets = false;
    }
  } else {
    patch.siteAccessGranted = false;
  }
  const {synced} = await saveExtensionSettings(patch);
  const permissionNote = needsSiteAccess && !patch.siteAccessGranted ? "；未授权网站访问，接管和页面组件已关闭" : "";
  show((synced ? "已保存并同步到 App" : "扩展已保存到 Chrome；App 当前未确认同步") + permissionNote + "。", !synced);
});
document.getElementById("check").addEventListener("click", async () => { const value=await ping(); document.getElementById("connection").textContent=value.connected?`已连接 · ${value.channel}`:"未连接"; });
document.getElementById("headerPermission").addEventListener("click", async () => { const granted=await chrome.permissions.request({permissions:["cookies","webRequest"],origins:["http://*/*","https://*/*"]}); await saveConfig({requestHeadersPermissionGranted:granted}); show(granted?"请求头权限已授权。":"未授权请求头权限。",!granted); });
function show(message, isError) { const output=document.getElementById("result"); output.textContent=message; output.dataset.error=String(isError); }
