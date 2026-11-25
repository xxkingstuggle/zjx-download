import {getConfig, saveConfig, validPort} from "./storage.js";
import {fetchExtensionSettings, fetchStatus, ping, saveExtensionSettings} from "./app-api.js";
import {normalizeExtensions, normalizeIgnoredPatterns} from "./utils.js";

const fields = [
  "port", "apiKey", "autoCapture", "minimumSizeKB", "extensions",
  "ignoredPatterns", "closeCapturedTab", "showPageWidgets",
  "sendRequestHeaders", "bypassKey", "silentAdd", "silentStart"
];

const syncPill = document.getElementById("syncPill");
const connectionBadge = document.getElementById("connection");
const apiKeyWarning = document.getElementById("apiKeyWarning");
const sitePermBadge = document.getElementById("sitePermBadge");
const headerPermBadge = document.getElementById("headerPermBadge");
const silentAddInput = document.getElementById("silentAdd");
const silentStartInput = document.getElementById("silentStart");
const apiKeyInput = document.getElementById("apiKey");
const toggleApiKeyBtn = document.getElementById("toggleApiKey");
const resultEl = document.getElementById("result");

function show(message, isError = false) {
  resultEl.textContent = message;
  resultEl.dataset.error = String(Boolean(isError));
  resultEl.dataset.ok = String(!isError);
}

function syncSilentStartState() {
  if (!silentAddInput.checked) {
    silentStartInput.checked = false;
    silentStartInput.disabled = true;
  } else {
    silentStartInput.disabled = false;
  }
}

function updateApiKeyBanner(requiresKey) {
  const needsKey = Boolean(requiresKey) && !apiKeyInput.value.trim();
  apiKeyWarning.hidden = !needsKey;
}

async function refreshPermissionBadges() {
  const [siteGranted, headersGranted] = await Promise.all([
    chrome.permissions.contains({permissions: ["webRequest"], origins: ["http://*/*", "https://*/*"]}).catch(() => false),
    chrome.permissions.contains({permissions: ["cookies", "webRequest"], origins: ["http://*/*", "https://*/*"]}).catch(() => false)
  ]);
  sitePermBadge.textContent = siteGranted ? "已授权" : "未授权";
  sitePermBadge.className = `pill-badge ${siteGranted ? "ok" : ""}`;
  headerPermBadge.textContent = headersGranted ? "已授权" : "未授权";
  headerPermBadge.className = `pill-badge ${headersGranted ? "ok" : ""}`;
  return {siteGranted, headersGranted};
}

async function checkConnection() {
  connectionBadge.textContent = "检测中…";
  connectionBadge.className = "pill-badge";
  const [pingResult, statusResult] = await Promise.all([ping(), fetchStatus()]);
  if (pingResult.connected) {
    const ver = statusResult?.status?.version ? ` · v${statusResult.status.version}` : "";
    const active = statusResult?.status ? ` · 活跃 ${statusResult.status.activeCount}` : "";
    connectionBadge.textContent = `已连接 (${pingResult.channel}${ver}${active})`;
    connectionBadge.className = "pill-badge ok";
    updateApiKeyBanner(statusResult?.status?.apiRequiresKey);
    return true;
  }
  if (pingResult.unauthorized || statusResult?.unauthorized) {
    connectionBadge.textContent = "API Key 无效或缺失";
    connectionBadge.className = "pill-badge warn";
    updateApiKeyBanner(true);
    return false;
  }
  connectionBadge.textContent = "未连接（App 未启动或端口不一致）";
  connectionBadge.className = "pill-badge warn";
  return false;
}

function render(value) {
  for (const id of fields) {
    const element = document.getElementById(id);
    if (!element) continue;
    if (element.type === "checkbox") {
      element.checked = Boolean(value[id]);
    } else if (id === "extensions") {
      element.value = (value.extensions || []).join(", ");
    } else if (id === "ignoredPatterns") {
      element.value = (value.ignoredPatterns || []).join("\n");
    } else {
      element.value = value[id] ?? "";
    }
  }
  syncSilentStartState();
  updateApiKeyBanner(value.apiRequiresKey);
}

const remote = await fetchExtensionSettings();
if (remote) {
  const {apiPort, apiRequiresKey, ...preferences} = remote;
  await saveConfig({
    ...preferences,
    apiRequiresKey: Boolean(apiRequiresKey),
    ...(validPort(apiPort) ? {port: Number(apiPort)} : {})
  });
  syncPill.textContent = "已与本机 App 同步";
  syncPill.className = "pill-badge ok";
} else {
  syncPill.textContent = "离线 · 使用 Chrome 本地配置";
  syncPill.className = "pill-badge warn";
}

const initialConfig = await getConfig();
let currentConfig = {...initialConfig};
render(currentConfig);
await Promise.all([refreshPermissionBadges(), checkConnection()]);

silentAddInput.addEventListener("change", syncSilentStartState);
apiKeyInput.addEventListener("input", () => updateApiKeyBanner(currentConfig.apiRequiresKey));
toggleApiKeyBtn.addEventListener("click", () => {
  const hidden = apiKeyInput.type === "password";
  apiKeyInput.type = hidden ? "text" : "password";
  toggleApiKeyBtn.textContent = hidden ? "隐藏" : "显示";
});

document.getElementById("check").addEventListener("click", async () => {
  const port = Number(document.getElementById("port").value);
  if (!validPort(port)) return show("端口必须为 1024–65535。", true);
  await saveConfig({port, apiKey: apiKeyInput.value});
  const ok = await checkConnection();
  show(ok ? "连接正常，端口与鉴权已通过验证。" : "无法连接或鉴权失败，请检查本机 App 状态与 API Key。", !ok);
});

document.getElementById("sitePermissionBtn").addEventListener("click", async () => {
  const granted = await chrome.permissions.request({permissions: ["webRequest"], origins: ["http://*/*", "https://*/*"]});
  await saveConfig({siteAccessGranted: granted});
  await refreshPermissionBadges();
  show(granted ? "网站访问与下载监听权限已授权。" : "未授权网站访问权限。", !granted);
});

document.getElementById("headerPermission").addEventListener("click", async () => {
  const granted = await chrome.permissions.request({permissions: ["cookies", "webRequest"], origins: ["http://*/*", "https://*/*"]});
  await saveConfig({requestHeadersPermissionGranted: granted});
  await refreshPermissionBadges();
  show(granted ? "Cookie 与请求头权限已授权。" : "未授权请求头权限。", !granted);
});

document.getElementById("save").addEventListener("click", async () => {
  const port = Number(document.getElementById("port").value);
  if (!validPort(port)) return show("端口必须为 1024–65535。", true);
  const minSize = Number(document.getElementById("minimumSizeKB").value);
  if (!Number.isFinite(minSize) || minSize < 0) return show("最小文件大小必须为非负整数。", true);

  const patch = {};
  for (const id of fields) {
    const element = document.getElementById(id);
    if (element.type === "checkbox") patch[id] = element.checked;
    else if (id === "port") patch[id] = port;
    else if (id === "minimumSizeKB") patch[id] = Math.floor(minSize);
    else if (id === "extensions") patch[id] = normalizeExtensions(element.value);
    else if (id === "ignoredPatterns") patch[id] = normalizeIgnoredPatterns(element.value);
    else patch[id] = element.value;
  }
  if (!patch.silentAdd) patch.silentStart = false;

  const needsSiteAccess = patch.autoCapture || patch.showPageWidgets;
  const requestedPermissions = [
    ...(needsSiteAccess || patch.sendRequestHeaders ? ["webRequest"] : []),
    ...(patch.sendRequestHeaders ? ["cookies"] : [])
  ];
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

  await saveConfig({port: patch.port, apiKey: patch.apiKey});
  const {synced} = await saveExtensionSettings(patch);
  currentConfig = {...currentConfig, ...patch};
  render(currentConfig);
  await refreshPermissionBadges();
  syncPill.textContent = synced ? "已与本机 App 同步" : "仅保存到 Chrome 本地";
  syncPill.className = `pill-badge ${synced ? "ok" : "warn"}`;
  const permissionNote = needsSiteAccess && !patch.siteAccessGranted ? "；未授权网站访问，接管和页面组件已关闭" : "";
  show((synced ? "已保存并同步到 App" : "扩展已保存到 Chrome；App 当前未确认同步") + permissionNote + "。", !synced);
  await checkConnection();
});
