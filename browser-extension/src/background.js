import {getConfig, saveConfig, validPort} from "./storage.js";
import {controlTask, fetchExtensionSettings, fetchStatus, fetchTasks, ping, saveExtensionSettings, sendItems} from "./app-api.js";
import {isHttpUrl, matchesExtension, parseContentDispositionName, wildcardMatch} from "./utils.js";

const icon = chrome.runtime.getURL("icons/icon-16.png");
const requestHeadersByID = new Map();
const activeCaptures = new Map();
const recentDownloadEvents = new Map();
const pendingHLSRequests = new Map();
const bypassedTabs = new Set();
const tabMediaCandidates = new Map();
const HANDOFF_WATCHDOG_ALARM = "zjx-handoff-watchdog";
const MAX_CANDIDATES_PER_TAB = 30;
const MAX_TRACKED = 300;
const MAX_CAPTURE_READINESS_WAITERS = 300;
const MAX_PENDING_HANDOFFS = 4;
const MAX_PENDING_HLS_REQUESTS = 4;
const HEADER_MAX_AGE_MS = 30_000;
const CAPTURE_MAX_AGE_MS = 15_000;
const DOWNLOAD_EVENT_SKEW_MS = 5_000;
const DOWNLOAD_SETTLE_MS = 250;
const HANDOFF_MAX_AGE_MS = 130_000;
const HANDOFF_SESSION_KEY = "zjxAutomaticHandoffs";
const HANDOFF_JOURNAL_MAX = MAX_PENDING_HANDOFFS;
let settingsSync = null;
let effectiveConfigCache = null;
let effectiveConfigCachedAt = 0;
let cookiesPermissionGranted = false;
let captureListenersEnabled = false;
let captureStateInitialized = false;
let automaticCaptureEnabled = false;
let sendRequestHeadersEnabled = false;
let captureEpoch = 0;
let captureRefreshGeneration = 0;
let captureRefreshChain = Promise.resolve();
let captureRefreshScheduled = false;
let captureReadinessWaiters = 0;
let recoveryPromise = null;
let journalWriteChain = Promise.resolve();
let menuRebuildChain = Promise.resolve();
let keepAliveTimer = null;
const handoffJournal = new Map();

registerCaptureListenersSynchronously();
chrome.runtime.onInstalled.addListener(() => { rebuildMenus(); startCaptureIfAllowed(); void ensureHandoffRecovery(); });
chrome.runtime.onStartup.addListener(() => { rebuildMenus(); startCaptureIfAllowed(); void ensureHandoffRecovery(); });
chrome.storage.onChanged.addListener((_changes, areaName) => {
  if (areaName === "session") return;
  effectiveConfigCache = null;
  if (_changes?.sendRequestHeaders?.newValue === false) {
    requestHeadersByID.clear();
    abortPendingHLSRequests();
    clearCaptures();
  }
  rebuildMenus();
  startCaptureIfAllowed();
});
chrome.tabs.onRemoved.addListener(tabId => {
  bypassedTabs.delete(tabId);
  tabMediaCandidates.delete(tabId);
  for (const [key, record] of requestHeadersByID) if (record.tabId === tabId) requestHeadersByID.delete(key);
  for (const [id, capture] of activeCaptures) {
    if (capture.tabId === tabId && capture.state === "candidate") discardCapture(id);
  }
});
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.status === "loading") {
    bypassedTabs.delete(tabId);
    tabMediaCandidates.delete(tabId);
  }
  if (changeInfo.status === "complete" && tab.url) injectContentScript(tabId, tab.url);
});
chrome.commands?.onCommand.addListener(async command => {
  if (command !== "toggle-auto-capture") return;
  const config = await getEffectiveConfig();
  const next = !config.autoCapture;
  if (next) {
    let granted = false;
    try {
      granted = await chrome.permissions.contains({permissions: ["webRequest"], origins: ["http://*/*", "https://*/*"]});
    } catch {}
    if (!granted) {
      await notify("zjx-download：需要网站权限", "请先在扩展弹窗或设置页授权网站访问权限，再开启自动接管。", null, false);
      return;
    }
  }
  const {synced} = await saveExtensionSettings({autoCapture: next, ...(next ? {siteAccessGranted: true} : {})});
  effectiveConfigCache = null;
  await notify(
    "zjx-download",
    next
      ? (synced ? "已通过快捷键开启自动接管（已同步 App）。" : "已通过快捷键开启自动接管。")
      : (synced ? "已通过快捷键关闭自动接管（已同步 App）。" : "已通过快捷键关闭自动接管。"),
    null,
    false
  );
});
chrome.alarms?.onAlarm.addListener(async alarm => {
  if (alarm?.name !== HANDOFF_WATCHDOG_ALARM) return;
  pruneCaptureCache();
  if (pendingHandoffCount() > 0) {
    ensureHandoffKeepAlive();
    return;
  }
  try {
    const stored = await chrome.storage.session.get(HANDOFF_SESSION_KEY);
    const records = Array.isArray(stored?.[HANDOFF_SESSION_KEY]) ? stored[HANDOFF_SESSION_KEY] : [];
    if (records.length > 0) {
      recoveryPromise = null;
      await ensureHandoffRecovery();
    } else {
      await clearHandoffWatchdogIfIdle();
    }
  } catch {}
});
chrome.permissions.onRemoved.addListener(permissions => {
  effectiveConfigCache = null;
  const revoked = new Set(permissions?.permissions || []);
  if (revoked.has("webRequest") || (permissions?.origins || []).length > 0) {
    disableCaptureListeners();
    getConfig().then(config => broadcastConfig({...config, siteAccessGranted: false})).catch(() => {});
  }
  else if (revoked.has("cookies")) {
    cookiesPermissionGranted = false;
    requestHeadersByID.clear();
    abortPendingHLSRequests();
    clearCaptures();
    try { chrome.webRequest.onBeforeSendHeaders.removeListener(onBeforeSendHeaders); } catch {}
  }
  startCaptureIfAllowed();
});
chrome.permissions.onAdded.addListener(() => {
  effectiveConfigCache = null;
  startCaptureIfAllowed();
});
rebuildMenus();
void startCaptureIfAllowed();

async function rebuildMenus() {
  const operation = menuRebuildChain.catch(() => {}).then(async () => {
    await new Promise(resolve => {
      chrome.contextMenus.removeAll(() => {
        void chrome.runtime.lastError;
        resolve();
      });
    });
    const definitions = [
      {id: "zjx-download-link", title: "使用 zjx-download 下载", contexts: ["link", "image", "video", "audio"]},
      {id: "zjx-download-selection", title: "下载选中区域中的链接…", contexts: ["selection"]},
      {id: "zjx-download-page", title: "下载当前页媒体候选", contexts: ["page"]}
    ];
    for (const definition of definitions) {
      await new Promise(resolve => {
        chrome.contextMenus.create(definition, () => {
          void chrome.runtime.lastError;
          resolve();
        });
      });
    }
  });
  menuRebuildChain = operation;
  await operation;
}

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (tab?.id == null) return;
  const config = await getEffectiveConfig();
  if (info.menuItemId === "zjx-download-selection") {
    let result = [];
    try {
      [{result = []} = {}] = await chrome.scripting.executeScript({target: {tabId: tab.id}, func: selectedLinks});
    } catch {
      return notify("zjx-download", "此网站尚未获得访问授权。请在扩展选项中授权后重试。", tab.id);
    }
    if (result.length === 0) return notify("zjx-download", "选区中没有可下载链接。", tab.id);
    return submit(result.map(item => ({...item, downloadPage: tab.url, description: item.text})), tab.id);
  }
  if (info.menuItemId === "zjx-download-page") return showTabCandidates(tab.id);
  const url = info.linkUrl || info.srcUrl;
  if (!url || !isHTTP(url)) return notify("zjx-download", "目标不是有效的 HTTP(S) 地址。", tab.id);
  const item = {link: url, type: "http", downloadPage: tab.url || "", description: info.selectionText || ""};
  if (config.sendRequestHeaders) {
    const headerResult = await requestHeaders(url, tab.id, info.frameId);
    item.headers = headerResult.headers;
    if (headerResult.warning) await notify("zjx-download：认证信息未匹配", headerResult.warning, tab.id, false);
  }
  await submit([item], tab.id);
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  (async () => {
    if (message?.type === "zjx-selection") {
      const config = await getEffectiveConfig();
      if (config.showPageWidgets && message.items?.length) await sendToContent(sender.tab?.id, {type: "zjx-selection-candidates", items: message.items}, sender.frameId);
      sendResponse({ok: true});
      return;
    }
    if (message?.type === "zjx-submit") { sendResponse(await submit(message.items, sender.tab?.id)); return; }
    if (message?.type === "zjx-ping") { sendResponse(await ping()); return; }
    if (message?.type === "zjx-status") {
      const [pingResult, statusResult] = await Promise.all([ping(), fetchStatus()]);
      sendResponse({ping: pingResult, status: statusResult});
      return;
    }
    if (message?.type === "zjx-tasks") { sendResponse(await fetchTasks()); return; }
    if (message?.type === "zjx-task-action") { sendResponse(await controlTask(message.id, message.action)); return; }
    if (message?.type === "zjx-tab-media-count") {
      const targetTabId = sender.tab?.id ?? message.tabId;
      const map = targetTabId != null ? tabMediaCandidates.get(targetTabId) : null;
      sendResponse({count: map ? map.size : 0});
      return;
    }
    if (message?.type === "zjx-config") { sendResponse({...await getEffectiveConfig(), cookiesPermissionGranted}); return; }
    if (message?.type === "zjx-show-candidates") { sendResponse(await showTabCandidates(sender.tab?.id ?? message.tabId)); return; }
    if (message?.type === "zjx-bypass") {
      if (sender.tab?.id != null) {
        if (message.active) bypassedTabs.add(sender.tab.id);
        else bypassedTabs.delete(sender.tab.id);
        if (message.active) {
          for (const [id, capture] of activeCaptures) {
            if (capture.tabId === sender.tab.id && capture.state !== "accepted") discardCapture(id, {notice: "已启用此标签页的旁路；Chrome 下载已保留或恢复。"});
          }
        }
      }
      sendResponse({ok: true});
      return;
    }
    sendResponse({ok: false, error: "未知扩展消息。"});
  })().catch(error => sendResponse({accepted: false, error: error.message}));
  return true;
});

async function submit(items, tabId, {requestID = crypto.randomUUID(), timeoutMs} = {}) {
  try {
    if (!Array.isArray(items) || items.length === 0) throw new Error("没有可发送的下载请求。");
    const config = await getEffectiveConfig();
    const result = await sendItems(items, {silentStart: config.silentStart, requestID, timeoutMs});
    const count = result.acceptedCount;
    if (!result.accepted) {
      const firstError = result.items.find(item => item.error)?.error;
      const message = result.declined ? "请求已拒绝；Chrome 下载保持原样。" : `App 没有接收此请求。${firstError ? ` ${firstError}` : ""}`;
      await notify("zjx-download", message, tabId);
      return {...result, count: 0, partial: false, message};
    }
    const partial = count < items.length;
    const declinedItems = result.items.filter(item => item.taskID === null);
    const declinedSummary = declinedItems.map(item => `第${item.index + 1}项${item.error ? `：${item.error.slice(0, 90)}` : ""}`).join("；");
    const message = partial
      ? `App 已接收 ${count}/${items.length} 项；${declinedSummary || "其余请求未接收"}。文件下载状态请在 App 中查看。`
      : `App 已接收 ${count} 项。文件下载状态请在 App 中查看。`;
    await notify("zjx-download", message, tabId, false);
    return {...result, count, partial, message};
  } catch (error) {
    await notify("zjx-download：交接失败", error.message, tabId);
    return {accepted: false, acceptedCount: 0, acceptedTaskIDs: [], items: [], count: 0, partial: false, error: error.message, message: error.message};
  }
}

async function notify(title, message, tabId, notifyContent = true) {
  message = typeof message === "string" ? message : String(message ?? "操作失败。");
  try {
    await chrome.notifications.create(`zjx-${Date.now()}-${crypto.randomUUID()}`, {type: "basic", iconUrl: icon, title, message: message.slice(0, 240)});
  } catch {}
  if (notifyContent && tabId != null) await sendToContent(tabId, {type: "zjx-error", message});
}
async function sendToContent(tabId, message, frameId) {
  if (tabId == null) return;
  try {
    if (Number.isInteger(frameId) && frameId >= 0) await chrome.tabs.sendMessage(tabId, message, {frameId});
    else await chrome.tabs.sendMessage(tabId, message);
  } catch {}
}
async function requestHeaders(url, tabId, frameId) {
  const result = {};
  let warning = "";
  pruneHeaderCache();
  const normalized = normalizeURL(url);
  const matching = Number.isInteger(tabId) && Number.isInteger(frameId) && normalized
    ? [...requestHeadersByID.values()].filter(record => record.tabId === tabId && record.frameId === frameId && record.url === normalized && record.method === "GET" && Date.now() - record.recordedAt >= 0 && Date.now() - record.recordedAt <= HEADER_MAX_AGE_MS)
    : [];
  if (matching.length === 1) Object.assign(result, matching[0].headers);
  else warning = "无法确定认证信息，可在App补充请求头/选择对应媒体资源。";
  try { cookiesPermissionGranted = await chrome.permissions.contains({permissions: ["cookies"]}); }
  catch { cookiesPermissionGranted = false; }
  if (!cookiesPermissionGranted) {
    for (const key of Object.keys(result)) if (key.toLowerCase() === "cookie") delete result[key];
    if (matching.length === 1) warning = "Chrome Cookies权限未授权，Cookie未发送；如需登录态请在App补充请求头。";
  }
  if (cookiesPermissionGranted) {
    try {
      const cookies = await chrome.cookies.getAll({url});
      if (cookies.length) result.Cookie = cookies.map(c => `${c.name}=${c.value}`).join("; ");
    } catch {}
  }
  try { const [tab] = await chrome.tabs.query({active: true, currentWindow: true}); if (tab?.id === tabId) result["User-Agent"] = navigator.userAgent; } catch {}
  return {headers: result, warning};
}

async function getEffectiveConfig() {
  if (effectiveConfigCache && Date.now() - effectiveConfigCachedAt < 5000) return effectiveConfigCache;
  const local = await getConfig();
  if (!settingsSync) {
    settingsSync = fetchExtensionSettings().finally(() => { settingsSync = null; });
  }
  const remote = await settingsSync;
  if (!remote) {
    effectiveConfigCache = local;
    effectiveConfigCachedAt = Date.now();
    return local;
  }
  const {apiPort, apiRequiresKey, ...preferences} = remote;
  const patch = {...preferences};
  if (validPort(apiPort)) patch.port = Number(apiPort);
  patch.apiRequiresKey = Boolean(apiRequiresKey);
  const changed = Object.entries(patch).some(([key, value]) => JSON.stringify(local[key]) !== JSON.stringify(value));
  const effective = {...local, ...patch};
  effectiveConfigCache = effective;
  effectiveConfigCachedAt = Date.now();
  if (changed) await saveConfig(patch);
  return effective;
}
function selectedLinks() {
  const selection = window.getSelection(); if (!selection || selection.isCollapsed) return [];
  const found = new Map();
  for (const anchor of document.querySelectorAll("a[href]")) {
    try {
      if (Array.from({length: selection.rangeCount}, (_, index) => index).some(index => selection.getRangeAt(index).intersectsNode(anchor))) {
        const link = new URL(anchor.href, location.href).href;
        if (["http:", "https:"].includes(new URL(link).protocol) && !found.has(link)) found.set(link, {link, text: anchor.textContent?.trim() || anchor.title || link});
      }
    } catch {}
  }
  return [...found.values()];
}

async function startCaptureIfAllowed() {
  captureRefreshGeneration++;
  if (captureRefreshScheduled) return captureRefreshChain;
  captureRefreshScheduled = true;
  captureRefreshChain = captureRefreshChain.catch(() => {}).then(async () => {
    try {
      let generation;
      do {
        generation = captureRefreshGeneration;
        await refreshCaptureListeners(generation);
      } while (generation !== captureRefreshGeneration);
    } finally { captureRefreshScheduled = false; }
  });
  return captureRefreshChain;
}
async function ensureCaptureReady() {
  if (!captureStateInitialized || captureRefreshScheduled) {
    if (captureReadinessWaiters >= MAX_CAPTURE_READINESS_WAITERS) return false;
    captureReadinessWaiters++;
    try {
      if (captureRefreshScheduled) await captureRefreshChain;
      else await startCaptureIfAllowed();
    } finally { captureReadinessWaiters--; }
  }
  return captureStateInitialized && captureListenersEnabled;
}
async function refreshCaptureListeners(generation) {
  const recoveryAvailable = await ensureHandoffRecovery();
  if (!recoveryAvailable) {
    automaticCaptureEnabled = false;
    try { chrome.downloads.onCreated.removeListener(onDownloadCreated); } catch {}
  }
  let config;
  try { config = await getEffectiveConfig(); } catch { return; }
  const enabled = config.autoCapture || config.showPageWidgets || config.sendRequestHeaders;
  let permitted = false;
  try {
    cookiesPermissionGranted = await chrome.permissions.contains({permissions: ["cookies"]});
    permitted = enabled && config.siteAccessGranted && await chrome.permissions.contains({permissions: ["webRequest"], origins: ["http://*/*", "https://*/*"]});
  } catch { cookiesPermissionGranted = false; }
  if (generation !== captureRefreshGeneration) return;
  captureStateInitialized = true;
  if (!permitted) {
    disableCaptureListeners(false);
    await broadcastConfig({...config, siteAccessGranted: false});
    return;
  }

  if (!captureListenersEnabled) captureEpoch++;
  if (!config.showPageWidgets || (sendRequestHeadersEnabled && !config.sendRequestHeaders)) abortPendingHLSRequests();
  captureListenersEnabled = true;
  try {
    if (config.autoCapture || config.showPageWidgets) {
      if (!chrome.webRequest.onHeadersReceived.hasListener(onHeadersReceived)) chrome.webRequest.onHeadersReceived.addListener(onHeadersReceived, {urls: ["http://*/*", "https://*/*"], types: ["main_frame", "sub_frame", "xmlhttprequest", "media"]}, ["responseHeaders"]);
    } else {
      chrome.webRequest.onHeadersReceived.removeListener(onHeadersReceived);
    }
    sendRequestHeadersEnabled = Boolean(config.sendRequestHeaders);
    if (config.sendRequestHeaders || config.autoCapture) {
      if (!chrome.webRequest.onBeforeSendHeaders.hasListener(onBeforeSendHeaders)) chrome.webRequest.onBeforeSendHeaders.addListener(onBeforeSendHeaders, {urls: ["http://*/*", "https://*/*"], types: ["main_frame", "sub_frame", "xmlhttprequest", "media"]}, ["requestHeaders", "extraHeaders"]);
    } else {
      chrome.webRequest.onBeforeSendHeaders.removeListener(onBeforeSendHeaders);
      requestHeadersByID.clear();
    }
    if (config.autoCapture && recoveryAvailable) {
      automaticCaptureEnabled = true;
      if (!chrome.downloads.onCreated.hasListener(onDownloadCreated)) chrome.downloads.onCreated.addListener(onDownloadCreated);
    } else {
      disableAutomaticCapture();
    }
  } catch {
    disableCaptureListeners(false);
    await broadcastConfig({...config, siteAccessGranted: false});
    return;
  }
  await broadcastConfig(config);
  for (const tab of await chrome.tabs.query({url: ["http://*/*", "https://*/*"]})) {
    if (generation !== captureRefreshGeneration) return;
    if (tab.id != null && tab.url) await injectContentScript(tab.id, tab.url);
  }
}
function disableCaptureListeners(invalidateRefresh = true) {
  if (invalidateRefresh) captureRefreshGeneration++;
  captureEpoch++;
  captureStateInitialized = true;
  captureListenersEnabled = false;
  automaticCaptureEnabled = false;
  sendRequestHeadersEnabled = false;
  try { chrome.webRequest.onHeadersReceived.removeListener(onHeadersReceived); } catch {}
  try { chrome.webRequest.onBeforeSendHeaders.removeListener(onBeforeSendHeaders); } catch {}
  try { chrome.downloads.onCreated.removeListener(onDownloadCreated); } catch {}
  requestHeadersByID.clear();
  abortPendingHLSRequests();
  clearCaptures();
}
function disableAutomaticCapture() {
  if (automaticCaptureEnabled || activeCaptures.size) captureEpoch++;
  automaticCaptureEnabled = false;
  try { chrome.downloads.onCreated.removeListener(onDownloadCreated); } catch {}
  clearCaptures();
}
async function injectContentScript(tabId, rawURL) {
  try {
    const config = await getEffectiveConfig();
    if (!captureListenersEnabled || !(config.autoCapture || config.showPageWidgets) || !config.siteAccessGranted) return;
    const url = new URL(rawURL);
    if (!["http:", "https:"].includes(url.protocol)) return;
    const originPattern = `${url.protocol}//${url.host}/*`;
    if (!await chrome.permissions.contains({origins: [originPattern]})) return;
    await chrome.scripting.executeScript({target: {tabId}, files: ["content.js"]});
    await sendToContent(tabId, {type: "zjx-config-updated", config: {...config, cookiesPermissionGranted}});
  } catch {}
}
async function broadcastConfig(config) {
  const tabs = await chrome.tabs.query({url: ["http://*/*", "https://*/*"]});
  const current = {...config, cookiesPermissionGranted};
  for (const tab of tabs) if (tab.id != null) await sendToContent(tab.id, {type: "zjx-config-updated", config: current});
}
async function onBeforeSendHeaders(details) {
  if (!Number.isInteger(details.tabId) || details.tabId < 0 || !await ensureCaptureReady() || bypassedTabs.has(details.tabId)) return;
  const out = {};
  for (const header of details.requestHeaders || []) {
    const name = header.name.toLowerCase();
    if (name !== "referer" && !sendRequestHeadersEnabled) continue;
    if (name === "cookie" && !cookiesPermissionGranted) continue;
    if (["cookie", "authorization", "user-agent", "referer", "accept", "range"].includes(name) && header.value) out[header.name] = header.value;
  }
  if (Object.keys(out).length) {
    const record = {headers: out, tabId: details.tabId, frameId: details.frameId, url: normalizeURL(details.url), method: details.method, recordedAt: Date.now()};
    if (typeof details.requestId === "string" && record.url) requestHeadersByID.set(details.requestId, record);
  }
  pruneHeaderCache();
}
async function onHeadersReceived(details) {
  if (!details.url || !Number.isInteger(details.tabId) || details.tabId < 0 || !isHTTP(details.url) || !await ensureCaptureReady()) return;
  const eventEpoch = captureEpoch;
  let config;
  try { config = await getEffectiveConfig(); } catch { return; }
  if (!captureListenersEnabled || eventEpoch !== captureEpoch) return;
  if (!config.autoCapture && !config.showPageWidgets) return;
  const bypassed = bypassedTabs.has(details.tabId);
  const page = details.documentUrl || details.initiator || "";
  if (isIgnored(details.url, page, config.ignoredPatterns)) return;
  const headers = Object.fromEntries((details.responseHeaders || []).map(h => [h.name.toLowerCase(), h.value || ""]));
  const mime = (headers["content-type"] || "").split(";")[0].toLowerCase();
  const size = Number(headers["content-length"] || 0);
  const name = fileName(headers["content-disposition"], details.url);
  if (details.url.toLowerCase().includes(".m3u8")) {
    if (!config.showPageWidgets || bypassed) return;
    if (pendingHLSRequests.size >= MAX_PENDING_HLS_REQUESTS || pendingHLSRequests.has(details.requestId)) return;
    const controller = new AbortController();
    pendingHLSRequests.set(details.requestId, controller);
    try {
      const variants = await parseHLS(details.url, page, config, details.tabId, details.frameId, details.requestId, controller.signal);
      if (pendingHLSRequests.get(details.requestId) !== controller || !captureListenersEnabled || eventEpoch !== captureEpoch) return;
      if (variants.length) {
        const enriched = variants.map(v => ({...v, page}));
        recordTabCandidates(details.tabId, enriched);
        await sendToContent(details.tabId, {type: "zjx-media-candidates", items: enriched}, details.frameId);
      }
    } finally { if (pendingHLSRequests.get(details.requestId) === controller) pendingHLSRequests.delete(details.requestId); }
    return;
  }
  if (mime.startsWith("audio/") || mime.startsWith("video/")) {
    if (!config.showPageWidgets || bypassed) return;
    let mediaPath = "";
    try { mediaPath = new URL(details.url).pathname.toLowerCase(); } catch {}
    if (/\.(?:ts|m4s|cmfv|cmfa|aac)$/.test(mediaPath) || ["video/mp2t", "video/iso.segment"].includes(mime)) return;
    if (size && size < config.minimumSizeKB * 1024) return;
    const item = {link: details.url, type: "http", downloadPage: page, suggestedName: name, description: mime, headers: config.sendRequestHeaders ? getExactRequestHeaders(details) : {}};
    recordTabCandidates(details.tabId, [item]);
    await sendToContent(details.tabId, {type: "zjx-media-candidates", items: [item]}, details.frameId);
    return;
  }
  if (!config.autoCapture || bypassed || !["main_frame", "sub_frame"].includes(details.type) || details.method !== "GET" || details.statusCode < 200 || details.statusCode >= 300) return;
  if (mime.startsWith("text/") || !name || !matchesExtension(name, config.extensions) || (size && size < config.minimumSizeKB * 1024)) return;
  if (details.url.includes("youtube.com") || details.url.includes("youtu.be")) return;
  if (!automaticCaptureEnabled || !captureListenersEnabled) return;
  pruneCaptureCache();
  if ([...activeCaptures.values()].some(capture => capture.webRequestID === details.requestId && capture.tabId === details.tabId)) return;
  const normalizedURL = normalizeURL(details.url);
  if (!normalizedURL) return;
  const requestHeaders = getRequestHeaderRecord(details);
  const refererHeader = requestHeaders?.headers?.Referer || requestHeaders?.headers?.referer;
  const referrer = normalizeURL(requestHeaders ? (refererHeader || "") : (details.documentUrl || "")) || "";
  const requestID = crypto.randomUUID();
  const requestAt = Number.isFinite(details.timeStamp) ? details.timeStamp : Date.now();
  const capture = {
    id: crypto.randomUUID(),
    state: "candidate",
    requestID,
    webRequestID: details.requestId,
    tabId: details.tabId,
    frameId: details.frameId,
    url: normalizedURL,
    referrer,
    requestAt,
    page,
    type: details.type,
    createdAt: Date.now(),
    expiresAt: Date.now() + CAPTURE_MAX_AGE_MS,
    epoch: captureEpoch,
    invalidated: false,
    downloads: [],
    settleTimer: null,
    expiryTimer: null,
    downloadID: null,
    extensionPaused: false,
    pauseIssued: false,
    item: {link: details.url, type: "http", downloadPage: page, suggestedName: name, description: "Chrome auto capture", headers: config.sendRequestHeaders ? getExactRequestHeaders(details) : {}}
  };
  capture.expiryTimer = setTimeout(() => discardCapture(capture.id), CAPTURE_MAX_AGE_MS);
  activeCaptures.set(capture.id, capture);
  while (activeCaptures.size > MAX_TRACKED) {
    const evict = [...activeCaptures].find(([, item]) => item.state !== "accepted");
    if (!evict) break;
    discardCapture(evict[0]);
  }
  const priorMatches = [...recentDownloadEvents.values()].filter(({download, recordedAt}) => downloadCouldMatchCapture(capture, download, recordedAt));
  if (priorMatches.length > 1) {
    discardCapture(capture.id, {notice: "Chrome 下载与请求的关联存在歧义，已保留 Chrome 项。"});
    return;
  }
  if (priorMatches.length === 1) {
    const {download} = priorMatches[0];
    void getDownloadByID(download.id).then(current => {
      if (current?.state === "in_progress") associateDownload(current);
      else recentDownloadEvents.delete(download.id);
    });
  }
}
async function onDownloadCreated(download) {
  if (!Number.isInteger(download?.id) || !await ensureCaptureReady() || !automaticCaptureEnabled || !captureListenersEnabled) return;
  pruneCaptureCache();
  recentDownloadEvents.set(download.id, {download, recordedAt: Date.now()});
  while (recentDownloadEvents.size > MAX_TRACKED) recentDownloadEvents.delete(recentDownloadEvents.keys().next().value);
  associateDownload(download);
}
function associateDownload(download) {
  if (!automaticCaptureEnabled || !captureListenersEnabled) return;
  const matches = matchingCaptures(download);
  if (matches.length > 1) {
    for (const capture of matches) discardCapture(capture.id);
    void notify("zjx-download：自动接管已跳过", "自动接管请求存在歧义，Chrome 下载已保留；请手动检查 App 和 Chrome。", download.tabId);
    return;
  }
  const capture = matches[0];
  if (!capture) return;
  if (!capture.downloads.some(item => item.id === download.id)) capture.downloads.push(download);
  if (capture.downloads.length > 1) return discardCapture(capture.id, {notice: "同一请求关联到多个 Chrome 下载，已保留 Chrome 项。"});
  if (capture.state !== "candidate") {
    return discardCapture(capture.id, {notice: "自动接管期间出现同源下载，Chrome 下载已保留；App 接收结果可能不确定，请检查两处状态。"});
  }
  clearTimeout(capture.settleTimer);
  capture.settleTimer = setTimeout(() => finalizeCapturedDownload(capture.id), DOWNLOAD_SETTLE_MS);
}
async function finalizeCapturedDownload(captureID) {
  const capture = activeCaptures.get(captureID);
  if (!capture || capture.state !== "candidate") return;
  capture.settleTimer = null;
  if (capture.downloads.length !== 1 || !captureIsCurrent(capture)) return discardCapture(captureID);
  const download = await getDownloadByID(capture.downloads[0].id);
  if (download === undefined) return discardCapture(captureID, {notice: "无法核验 Chrome 下载状态，下载保持在 Chrome，未提交 App。"});
  if (!download || download.state !== "in_progress" || download.paused || !captureIsCurrent(capture)) return discardCapture(captureID);
  const matches = matchingCaptures(download);
  if (matches.length !== 1 || matches[0] !== capture || await hasConcurrentChromeDownload(capture, download)) {
    for (const item of matches) discardCapture(item.id);
    discardCapture(captureID);
    void notify("zjx-download：自动接管已跳过", "自动接管关联不唯一或存在并行下载，Chrome 下载已保留。", capture.tabId);
    return;
  }
  if (!captureIsCurrent(capture) || !automaticCaptureEnabled || !captureListenersEnabled || pendingHandoffCount() >= MAX_PENDING_HANDOFFS || handoffJournal.size >= HANDOFF_JOURNAL_MAX) {
    return discardCapture(captureID);
  }

  capture.downloadID = download.id;
  capture.state = "pauseRequested";
  capture.handoffDeadline = Date.now() + HANDOFF_MAX_AGE_MS;
  capture.expiresAt = capture.handoffDeadline;
  clearTimeout(capture.expiryTimer);
  capture.expiryTimer = setTimeout(() => discardCapture(captureID, {notice: "App 接收等待超时，Chrome 下载已恢复；请检查 App 是否已接收。"}), HANDOFF_MAX_AGE_MS);
  try { await saveHandoffMarker(capture, "pauseRequested"); }
  catch {
    capture.state = "candidate";
    capture.expiresAt = capture.createdAt + CAPTURE_MAX_AGE_MS;
    return discardCapture(captureID, {notice: "无法保存交接恢复标记，Chrome 下载保持原样。"});
  }
  if (!handoffIsCurrent(capture)) return discardCapture(captureID);

  // The download may have changed while the session marker was being saved.
  // Recheck immediately before pause so a user-paused item is never claimed.
  const beforePause = await getDownloadByID(download.id);
  if (!beforePause || beforePause.state !== "in_progress" || beforePause.paused !== false || !handoffIsCurrent(capture)) {
    return discardCapture(captureID, {notice: "Chrome 下载状态在接管前发生变化，扩展未暂停或取消该项。"});
  }
  capture.pauseIssued = true;
  let pausePromise;
  try { pausePromise = Promise.resolve(chrome.downloads.pause(download.id)); }
  catch (error) { pausePromise = Promise.reject(error); }
  capture.pausePromise = pausePromise;
  try { await pausePromise; }
  catch {
    capture.pauseFailed = true;
    await restoreChromeDownload(capture);
    capture.state = "candidate";
    return discardCapture(captureID, {notice: "Chrome 未能确认暂停来源；下载已保留，请检查 Chrome 下载状态。"});
  } finally {
    if (capture.pausePromise === pausePromise) capture.pausePromise = null;
  }
  const pausedDownload = await waitForDownloadPaused(download.id);
  if (!pausedDownload || pausedDownload.state !== "in_progress" || pausedDownload.paused !== true || !handoffIsCurrent(capture)) {
    await restoreChromeDownload(capture);
    return discardCapture(captureID, {notice: "无法确认 Chrome 下载暂停状态，未提交 App。"});
  }
  capture.extensionPaused = true;
  capture.state = "pausedByExtension";
  try { await saveHandoffMarker(capture, "pausedByExtension"); }
  catch {
    await restoreChromeDownload(capture);
    return discardCapture(captureID, {notice: "无法保存暂停状态，Chrome 下载已恢复。"});
  }
  if (!handoffIsCurrent(capture) || matchingCaptures(pausedDownload).length !== 1 || await hasConcurrentChromeDownload(capture, pausedDownload)) {
    return discardCapture(captureID, {notice: "暂停后下载关联变得不唯一，Chrome 下载已恢复。"});
  }

  capture.state = "submitting";
  try { await saveHandoffMarker(capture, "submitting"); }
  catch { return discardCapture(captureID, {notice: "无法记录交接状态，Chrome 下载已恢复。"}); }
  const result = await submit([capture.item], capture.tabId, {requestID: capture.requestID, timeoutMs: HANDOFF_MAX_AGE_MS - 10_000});
  if (!handoffIsCurrent(capture)) {
    if (result?.accepted) await notify("zjx-download：交接结果不确定", "App 已报告接收，但扩展状态已中断；Chrome 下载已保留或恢复，请检查 App 和 Chrome，可能出现重复项。", capture.tabId);
    return;
  }
  const acceptedItem = result?.items?.find(item => item.index === 0);
  if (result?.accepted !== true || result.acceptedCount !== 1 || !Number.isSafeInteger(acceptedItem?.taskID) || acceptedItem.taskID <= 0) {
    const message = result?.error
      ? "App 接收状态未能核验；Chrome 下载已恢复。请检查 App 和 Chrome，可能出现重复项。"
      : "App 未明确接收该项目，Chrome 下载已恢复。";
    return discardCapture(captureID, {notice: message});
  }

  capture.state = "accepted";
  try { await saveHandoffMarker(capture, "accepted"); }
  catch {
    capture.state = "submitting";
    return discardCapture(captureID, {notice: "App 已接收，但恢复标记写入失败；Chrome 下载已恢复，请检查是否有重复项。"});
  }
  await cancelAcceptedChromeDownload(capture);
}
async function cancelAcceptedChromeDownload(capture) {
  if (activeCaptures.get(capture.id) !== capture || capture.state !== "accepted") return;
  const current = await getDownloadByID(capture.downloadID);
  if (current === undefined) {
    await resumeAcceptedChromeDownload(capture);
    removeCapture(capture.id);
    await notify("zjx-download：Chrome 状态不可核验", "App 已接收任务，但无法核验 Chrome 下载状态；已尝试恢复该 Chrome 项。请检查两处状态。", capture.tabId);
    return;
  }
  if (current === null || current.state !== "in_progress") {
    await clearHandoffMarker(capture.downloadID);
    recentDownloadEvents.delete(capture.downloadID);
    removeCapture(capture.id);
    if (current === null) await notify("zjx-download：Chrome 状态不可核验", "App 已接收任务，但 Chrome 中找不到对应下载项；请检查 App 和 Chrome。", capture.tabId);
    return;
  }
  if (current.paused !== true) {
    await clearHandoffMarker(capture.downloadID);
    removeCapture(capture.id);
    await notify("zjx-download：Chrome 下载仍在运行", "App 已接收此任务，但 Chrome 下载已不再暂停，因此未取消它。请检查两处状态。", capture.tabId);
    return;
  }
  let cancelError = null;
  try { await chrome.downloads.cancel(capture.downloadID); }
  catch (error) { cancelError = error; }
  const after = await waitForDownloadChange(capture.downloadID);
  if (after === undefined) {
    await resumeAcceptedChromeDownload(capture);
    removeCapture(capture.id);
    await notify("zjx-download：取消结果不确定", "App 已接收任务，但无法核验 Chrome 是否取消；已尝试恢复该 Chrome 项。请检查两处状态。", capture.tabId);
    return;
  }
  if (after === null || after.state !== "in_progress") {
    await clearHandoffMarker(capture.downloadID);
    recentDownloadEvents.delete(capture.downloadID);
    removeCapture(capture.id);
    if (cancelError) await notify("zjx-download：Chrome 项已结束", "App 已接收任务；Chrome 项已不再运行。", capture.tabId, false);
    await maybeCloseCapturedTab(capture);
    return;
  }
  if (after.paused === true) await resumeAcceptedChromeDownload(capture);
  else await clearHandoffMarker(capture.downloadID);
  removeCapture(capture.id);
  await notify("zjx-download：Chrome 下载未取消", "App 已接收任务，但 Chrome 下载无法取消；已尝试恢复 Chrome 项。请检查两处状态，避免重复下载。", capture.tabId);
}
async function resumeAcceptedChromeDownload(capture) {
  try { await chrome.downloads.resume(capture.downloadID); } catch {}
  const after = await getDownloadByID(capture.downloadID);
  const uncertain = after === undefined || (after?.state === "in_progress" && after.paused === true);
  if (uncertain) {
    try { await saveHandoffMarker(capture, "accepted"); } catch {}
  } else {
    await clearHandoffMarker(capture.downloadID);
  }
  return after;
}
async function maybeCloseCapturedTab(capture) {
  const config = await getEffectiveConfig().catch(() => null);
  if (!config?.closeCapturedTab || capture.page || capture.type !== "main_frame") return;
  try {
    const tab = await chrome.tabs.get(capture.tabId);
    if (tab.url && normalizeURL(tab.url) === capture.url) await chrome.tabs.remove(capture.tabId);
  } catch {}
}
async function hasConcurrentChromeDownload(capture, currentDownload) {
  if (!capture.url || !Number.isInteger(currentDownload?.id)) return true;
  try {
    const items = await chrome.downloads.search({state: "in_progress", orderBy: ["-startTime"], limit: MAX_TRACKED + 1});
    if (items.length > MAX_TRACKED) return true;
    const current = items.find(item => item.id === currentDownload.id);
    if (!current || current.state !== "in_progress") return true;
    const matches = items.filter(item => {
      if (item.state !== "in_progress") return false;
      const urls = [item.url, item.finalUrl].map(normalizeURL);
      const sameResource = urls.includes(capture.url);
      const sameReferrer = (normalizeURL(item.referrer) || "") === capture.referrer;
      return sameResource && sameReferrer;
    });
    return matches.length !== 1 || matches[0].id !== currentDownload.id;
  } catch {
    return true;
  }
}
function matchingCaptures(download) {
  return [...activeCaptures.values()].filter(capture => {
    const event = Number.isInteger(download?.id) ? recentDownloadEvents.get(download.id) : null;
    return captureIsRelevant(capture) && downloadCouldMatchCapture(capture, download, event?.recordedAt);
  });
}
function downloadCouldMatchCapture(capture, download, recordedAt) {
  if (!capture || !download || !Number.isInteger(download.id)) return false;
  const urls = new Set([download.url, download.finalUrl].map(normalizeURL).filter(Boolean));
  if (!urls.has(capture.url) || (normalizeURL(download.referrer) || "") !== capture.referrer) return false;
  const startedAt = Date.parse(download.startTime || "");
  if (!Number.isFinite(startedAt) || startedAt < capture.requestAt - DOWNLOAD_EVENT_SKEW_MS || startedAt > capture.requestAt + DOWNLOAD_EVENT_SKEW_MS) return false;
  if (Number.isFinite(recordedAt) && (recordedAt < capture.requestAt - DOWNLOAD_EVENT_SKEW_MS || recordedAt > Date.now() + DOWNLOAD_EVENT_SKEW_MS)) return false;
  return true;
}
function captureIsCurrent(capture) {
  return activeCaptures.get(capture.id) === capture && !capture.invalidated && capture.state === "candidate" && capture.epoch === captureEpoch && Date.now() <= capture.expiresAt;
}
function captureIsRelevant(capture) {
  if (activeCaptures.get(capture.id) !== capture || capture.invalidated || capture.state === "accepted" || capture.epoch !== captureEpoch) return false;
  return capture.state === "candidate" ? Date.now() <= capture.expiresAt : Date.now() <= (capture.handoffDeadline || 0);
}
function handoffIsCurrent(capture) {
  return activeCaptures.get(capture.id) === capture && !capture.invalidated && capture.epoch === captureEpoch && automaticCaptureEnabled && captureListenersEnabled && Date.now() <= (capture.handoffDeadline || 0);
}
function pendingHandoffCount() {
  return [...activeCaptures.values()].filter(capture => capture.state !== "candidate").length;
}
function pruneCaptureCache(now = Date.now()) {
  for (const [id, capture] of activeCaptures) {
    const expiresAt = capture.state === "candidate" ? capture.expiresAt : capture.handoffDeadline;
    if (capture.state !== "accepted" && (now > expiresAt || capture.epoch !== captureEpoch)) discardCapture(id);
  }
  for (const [id, record] of recentDownloadEvents) if (now - record.recordedAt > CAPTURE_MAX_AGE_MS) recentDownloadEvents.delete(id);
}
function discardCapture(id, {notice = ""} = {}) {
  const capture = activeCaptures.get(id);
  if (!capture) return;
  if (capture.state === "accepted") return;
  capture.invalidated = true;
  if (capture.extensionPaused || capture.pauseIssued) void restoreChromeDownload(capture, notice);
  else {
    if (capture.downloadID && !capture.recoveryPending) void clearHandoffMarker(capture.downloadID);
    if (notice) void notify("zjx-download：自动接管已跳过", notice, capture.tabId);
  }
  removeCapture(id);
}
function removeCapture(id) {
  const capture = activeCaptures.get(id);
  if (!capture) return;
  clearTimeout(capture.expiryTimer);
  clearTimeout(capture.settleTimer);
  activeCaptures.delete(id);
}
function clearCaptures() {
  for (const [id, capture] of activeCaptures) if (capture.state !== "accepted") discardCapture(id, {notice: "扩展捕获权限或设置已变化；Chrome 下载保持或已恢复，接收结果可能不确定。"});
}
function abortPendingHLSRequests() {
  for (const controller of pendingHLSRequests.values()) controller.abort();
  pendingHLSRequests.clear();
}
function pruneHeaderCache(now = Date.now()) {
  for (const [key, record] of requestHeadersByID) if (now - record.recordedAt > HEADER_MAX_AGE_MS) requestHeadersByID.delete(key);
  while (requestHeadersByID.size > MAX_TRACKED) requestHeadersByID.delete(requestHeadersByID.keys().next().value);
}
function getExactRequestHeaders(details) {
  pruneHeaderCache();
  const record = getRequestHeaderRecord(details);
  return record ? {...record.headers} : {};
}
function getRequestHeaderRecord(details) {
  pruneHeaderCache();
  const record = typeof details.requestId === "string" ? requestHeadersByID.get(details.requestId) : null;
  if (!record || record.tabId !== details.tabId || record.frameId !== details.frameId || record.url !== normalizeURL(details.url)) return null;
  return record;
}
async function getDownloadByID(id) {
  try { return (await chrome.downloads.search({id})).find(item => item.id === id) || null; }
  catch { return undefined; }
}
async function waitForDownloadChange(id) {
  let current;
  for (let attempt = 0; attempt < 5; attempt++) {
    current = await getDownloadByID(id);
    if (current === undefined || current === null || current.state !== "in_progress" || current.paused !== true) return current;
    if (attempt < 4) await new Promise(resolve => setTimeout(resolve, 200));
  }
  return current;
}
async function waitForDownloadPaused(id) {
  let current;
  for (let attempt = 0; attempt < 5; attempt++) {
    current = await getDownloadByID(id);
    if (current === undefined || current === null || current.state !== "in_progress" || current.paused === true) return current;
    if (attempt < 4) await new Promise(resolve => setTimeout(resolve, 150));
  }
  return current;
}
async function ensureHandoffRecovery() {
  if (!recoveryPromise) recoveryPromise = recoverInterruptedHandoffs();
  return recoveryPromise;
}
async function recoverInterruptedHandoffs() {
  let records;
  try {
    const stored = await chrome.storage.session.get(HANDOFF_SESSION_KEY);
    records = Array.isArray(stored?.[HANDOFF_SESSION_KEY]) ? stored[HANDOFF_SESSION_KEY] : [];
  } catch {
    await notify("zjx-download：交接恢复状态不可用", "扩展无法读取自动交接恢复记录；本次会话将停用自动接管。", null);
    return false;
  }
  for (const record of records) {
    if (!validHandoffMarker(record)) {
      if (Number.isSafeInteger(record?.downloadId) && record.downloadId >= 0) {
        await notify("zjx-download：交接记录无法识别", "扩展没有自动取消或恢复对应 Chrome 项；请手动检查下载状态。", null);
      }
      continue;
    }
    handoffJournal.set(record.downloadId, record);
  }
  for (const record of [...handoffJournal.values()]) {
    const download = await getDownloadByID(record.downloadId);
    if (download === undefined) {
      await notify("zjx-download：Chrome 状态不可核验", "扩展无法读取待恢复的 Chrome 项；自动接管已停用，未自动取消下载。", null);
      return false;
    }
    if (record.state === "accepted") {
      if (download === null || download.state !== "in_progress") {
        handoffJournal.delete(record.downloadId);
        continue;
      }
      if (download.paused !== true) {
        await notify("zjx-download：恢复时发现重复下载风险", "App 已明确接收该任务，但 Chrome 项当前未暂停；扩展没有取消它。请检查两处状态。", null);
        handoffJournal.delete(record.downloadId);
        continue;
      }
      try { await chrome.downloads.cancel(record.downloadId); } catch {}
      const after = await waitForDownloadChange(record.downloadId);
      if (after === undefined) {
        try { await chrome.downloads.resume(record.downloadId); } catch {}
        const afterResume = await getDownloadByID(record.downloadId);
        if (afterResume === undefined || (afterResume?.state === "in_progress" && afterResume.paused === true)) {
          await notify("zjx-download：取消结果不确定", "App 已接收任务，但扩展无法核验 Chrome 项是否取消或恢复；未再次取消，请手动检查。", null);
          return false;
        }
        if (afterResume?.state === "in_progress") {
          await notify("zjx-download：Chrome 项仍在运行", "App 已接收任务；Chrome 项已尝试恢复，请检查两处状态，避免重复下载。", null);
        }
        handoffJournal.delete(record.downloadId);
        continue;
      }
      if (after?.state === "in_progress") {
        let afterResume = after;
        if (after.paused === true) {
          try { await chrome.downloads.resume(record.downloadId); } catch {}
          afterResume = await getDownloadByID(record.downloadId);
        }
        if (afterResume === undefined || (afterResume?.state === "in_progress" && afterResume.paused === true)) {
          await notify("zjx-download：Chrome 项未能恢复", "App 已接收任务；Chrome 项仍暂停或状态不明，扩展保留恢复记录，请手动检查。", null);
          return false;
        }
        await notify("zjx-download：Chrome 项未能取消", "App 已接收任务；Chrome 项仍在运行，扩展已尝试恢复它。请检查两处状态，避免重复下载。", null);
      }
      handoffJournal.delete(record.downloadId);
      continue;
    }
    if (["pausedByExtension", "submitting", "resumePending"].includes(record.state)) {
      if (download?.state === "in_progress" && download.paused === true) {
        try { await chrome.downloads.resume(record.downloadId); } catch {}
        const after = await getDownloadByID(record.downloadId);
        if (after === undefined || after?.state === "in_progress" && after.paused === true) {
          await notify("zjx-download：Chrome 下载恢复未确认", "App 接收状态不确定，扩展没有取消 Chrome 项；请手动检查并恢复下载。自动接管已停用。", null);
          return false;
        }
      }
      await notify("zjx-download：自动交接中断", "扩展已恢复或尝试恢复 Chrome 下载；App 接收状态不确定，未自动取消 Chrome 项。请检查 App 和 Chrome，可能出现重复项。", null);
      handoffJournal.delete(record.downloadId);
      continue;
    }
    if (record.state === "pauseRequested" && download?.state === "in_progress" && download.paused === true) {
      await notify("zjx-download：暂停状态不确定", "扩展无法确认此 Chrome 项是否由自己暂停，因此没有自动恢复或取消它。请在 Chrome 下载列表中检查并手动恢复。", null);
    }
    handoffJournal.delete(record.downloadId);
  }
  try { await chrome.storage.session.set({[HANDOFF_SESSION_KEY]: [...handoffJournal.values()]}); }
  catch {
    await notify("zjx-download：交接恢复记录不可用", "扩展无法更新自动交接恢复记录；自动接管已停用。", null);
    return false;
  }
  return true;
}
function validHandoffMarker(record) {
  return record && typeof record === "object" && Number.isSafeInteger(record.downloadId) && record.downloadId >= 0 &&
    typeof record.requestId === "string" && record.requestId.length > 0 && record.requestId.length <= 128 &&
    ["pauseRequested", "pausedByExtension", "submitting", "accepted", "resumePending"].includes(record.state);
}
async function saveHandoffMarker(capture, state) {
  if (!await ensureHandoffRecovery()) throw new Error("恢复记录不可用");
  const marker = {downloadId: capture.downloadID, requestId: capture.requestID, state, updatedAt: Date.now()};
  if (!validHandoffMarker(marker)) throw new Error("恢复记录无效");
  const operation = journalWriteChain.catch(() => {}).then(async () => {
    const previous = handoffJournal.get(marker.downloadId);
    if (!previous && handoffJournal.size >= HANDOFF_JOURNAL_MAX) throw new Error("恢复记录容量已满");
    handoffJournal.set(marker.downloadId, marker);
    try { await chrome.storage.session.set({[HANDOFF_SESSION_KEY]: [...handoffJournal.values()]}); }
    catch (error) {
      if (previous) handoffJournal.set(marker.downloadId, previous);
      else handoffJournal.delete(marker.downloadId);
      throw error;
    }
  });
  journalWriteChain = operation;
  await operation;
  scheduleHandoffWatchdog();
}
async function clearHandoffMarker(downloadID) {
  const operation = journalWriteChain.catch(() => {}).then(async () => {
    const previous = handoffJournal.get(downloadID);
    if (!previous) return;
    handoffJournal.delete(downloadID);
    try { await chrome.storage.session.set({[HANDOFF_SESSION_KEY]: [...handoffJournal.values()]}); }
    catch (error) { handoffJournal.set(downloadID, previous); throw error; }
  });
  journalWriteChain = operation;
  try { await operation; } catch {}
  await clearHandoffWatchdogIfIdle();
}
async function restoreChromeDownload(capture, notice = "") {
  if (notice && !capture.restoreNotice) capture.restoreNotice = notice;
  if (capture.restoring) return;
  capture.restoring = true;
  let keepMarker = false;
  if (capture.downloadID) {
    if (capture.pausePromise) await capture.pausePromise.catch(() => {});
    const current = await getDownloadByID(capture.downloadID);
    if (capture.pauseFailed && (current === undefined || current?.state === "in_progress" && current.paused === true)) {
      // A rejected pause can race a user pause. Preserve a manual-recovery
      // marker instead of resuming a task whose pause owner is uncertain.
      try { await saveHandoffMarker(capture, "pauseRequested"); } catch {}
      keepMarker = true;
    } else if (capture.extensionPaused || capture.pauseIssued) {
      try { await saveHandoffMarker(capture, "resumePending"); } catch {}
      if (current?.state === "in_progress" && current.paused === true || current === undefined) {
      try { await chrome.downloads.resume(capture.downloadID); } catch {}
      const after = await getDownloadByID(capture.downloadID);
      keepMarker = after === undefined || (after?.state === "in_progress" && after.paused === true);
      }
    }
    if (!keepMarker) {
      if (current === undefined && !capture.pauseFailed && (capture.extensionPaused || capture.pauseIssued)) keepMarker = true;
      else await clearHandoffMarker(capture.downloadID);
    }
  }
  capture.extensionPaused = keepMarker && !capture.pauseFailed;
  capture.pauseIssued = keepMarker && !capture.pauseFailed;
  capture.recoveryPending = keepMarker;
  capture.restoring = false;
  const pendingNotice = capture.restoreNotice;
  capture.restoreNotice = "";
  if (pendingNotice) await notify("zjx-download：Chrome 下载已保留", pendingNotice, capture.tabId);
}
function normalizeURL(value) {
  if (typeof value !== "string" || !value) return "";
  try { const url = new URL(value); url.hash = ""; return url.href; } catch { return ""; }
}
function registerCaptureListenersSynchronously() {
  // MV3 service workers can receive a wake event before asynchronous settings
  // or recovery work finishes. Register lightweight listeners at evaluation
  // time; each callback awaits ensureCaptureReady() before doing any work.
  try {
    const event = chrome.webRequest?.onHeadersReceived;
    if (event && !event.hasListener(onHeadersReceived)) {
      event.addListener(onHeadersReceived, {urls: ["http://*/*", "https://*/*"], types: ["main_frame", "sub_frame", "xmlhttprequest", "media"]}, ["responseHeaders"]);
    }
  } catch {}
  try {
    const event = chrome.webRequest?.onBeforeSendHeaders;
    if (event && !event.hasListener(onBeforeSendHeaders)) {
      event.addListener(onBeforeSendHeaders, {urls: ["http://*/*", "https://*/*"], types: ["main_frame", "sub_frame", "xmlhttprequest", "media"]}, ["requestHeaders", "extraHeaders"]);
    }
  } catch {}
  try {
    const event = chrome.downloads?.onCreated;
    if (event && !event.hasListener(onDownloadCreated)) event.addListener(onDownloadCreated);
  } catch {}
}
function recordTabCandidates(tabId, items) {
  if (!Number.isInteger(tabId) || tabId < 0 || !Array.isArray(items) || !items.length) return;
  let bucket = tabMediaCandidates.get(tabId);
  if (!bucket) {
    bucket = new Map();
    tabMediaCandidates.set(tabId, bucket);
  }
  for (const item of items) {
    if (!item?.link) continue;
    bucket.delete(item.link);
    bucket.set(item.link, item);
  }
  while (bucket.size > MAX_CANDIDATES_PER_TAB) {
    bucket.delete(bucket.keys().next().value);
  }
}
function scheduleHandoffWatchdog() {
  try {
    chrome.alarms?.create(HANDOFF_WATCHDOG_ALARM, {delayInMinutes: 1, periodInMinutes: 1});
  } catch {}
  ensureHandoffKeepAlive();
}
function ensureHandoffKeepAlive() {
  if (keepAliveTimer) return;
  keepAliveTimer = setInterval(() => {
    if (pendingHandoffCount() === 0 && handoffJournal.size === 0) {
      clearInterval(keepAliveTimer);
      keepAliveTimer = null;
      return;
    }
    try { chrome.runtime.getPlatformInfo(() => { void chrome.runtime.lastError; }); } catch {}
  }, 20_000);
}
async function clearHandoffWatchdogIfIdle() {
  if (pendingHandoffCount() > 0 || handoffJournal.size > 0) return;
  if (keepAliveTimer) {
    clearInterval(keepAliveTimer);
    keepAliveTimer = null;
  }
  try { await chrome.alarms?.clear(HANDOFF_WATCHDOG_ALARM); } catch {}
}
async function showTabCandidates(tabId) {
  if (tabId == null) return {shown: false, count: 0, reason: "找不到活动标签页。"};
  let tab = null;
  try { tab = await chrome.tabs.get(tabId); } catch {}
  if (!tab?.url || !isHttpUrl(tab.url)) {
    return {shown: false, count: 0, reason: "当前页面不支持媒体抓取（仅支持 http/https 页面）。"};
  }
  const config = await getEffectiveConfig();
  if (!config.siteAccessGranted) {
    return {shown: false, count: 0, reason: "请先开启“显示选区与媒体候选”并授权网站访问权限。"};
  }
  await injectContentScript(tabId, tab.url);
  const cached = [...(tabMediaCandidates.get(tabId)?.values() || [])];
  try {
    const reply = await chrome.tabs.sendMessage(tabId, {type: "zjx-open-media", items: cached});
    const count = typeof reply?.count === "number" ? reply.count : cached.length;
    if (reply?.opened) return {shown: true, count};
    return {shown: false, count, reason: count === 0 ? "当前页面暂未捕获到音频、视频或 HLS 媒体流。" : "网页浮窗未显示，请检查是否关闭了页面候选开关。"};
  } catch {
    return {shown: false, count: cached.length, reason: "无法连接当前页面脚本，请刷新页面后重试。"};
  }
}
async function parseHLS(url, page, config, tabId, frameId, requestId, abortSignal) {
  const controller = new AbortController();
  const abort = () => controller.abort();
  if (abortSignal?.aborted) abort();
  else abortSignal?.addEventListener("abort", abort, {once: true});
  const timeout = setTimeout(abort, 5000);
  try {
    const sourceHeaders = config.sendRequestHeaders ? getExactRequestHeaders({url, tabId, frameId, requestId}) : {};
    if (!cookiesPermissionGranted) {
      for (const key of Object.keys(sourceHeaders)) if (key.toLowerCase() === "cookie") delete sourceHeaders[key];
    }
    const sourceOrigin = new URL(url).origin;
    const response = await fetch(url, {credentials: config.sendRequestHeaders && cookiesPermissionGranted ? "include" : "omit", headers: sourceHeaders, signal: controller.signal});
    if (!response.ok) return [];
    const text = await readBoundedResponseText(response, 2 * 1024 * 1024); if (text === null) return [];
    const lines = text.split(/\r?\n/); const result = [];
    for (let i = 0; i < lines.length; i++) if (lines[i].startsWith("#EXT-X-STREAM-INF")) {
      const attributes = Object.fromEntries([...lines[i].matchAll(/([A-Z0-9-]+)=((?:"[^"]*")|[^,]*)/g)].map(m => [m[1], m[2].replaceAll('"', '')]));
      let next = i + 1;
      while (next < lines.length && !lines[next].trim()) next++;
      const target = lines[next]?.trim();
      if (!target || target.startsWith("#")) continue;
      const variant = new URL(target, url).href;
      const variantHeaders = new URL(variant).origin === sourceOrigin ? sourceHeaders : {};
      result.push({link: variant, type: "hls", downloadPage: page, suggestedName: fileName("", variant) || "media.ts", description: `${attributes.RESOLUTION || "清晰度未知"} ${attributes.BANDWIDTH || ""}`, headers: variantHeaders});
    }
    if (!result.length && lines.some(line => line.startsWith("#EXTINF:")) && lines.some(line => !line.startsWith("#") && line.trim())) result.push({link: url, type: "hls", downloadPage: page, suggestedName: "media.ts", description: "HLS TS", headers: sourceHeaders});
    return result;
  } catch { return []; }
  finally {
    clearTimeout(timeout);
    abortSignal?.removeEventListener("abort", abort);
  }
}
async function readBoundedResponseText(response, maxBytes) {
  const reader = response.body?.getReader?.();
  if (!reader) {
    const text = await response.text();
    return new TextEncoder().encode(text).byteLength <= maxBytes ? text : null;
  }
  const decoder = new TextDecoder();
  const chunks = [];
  let totalBytes = 0;
  while (true) {
    const {done, value} = await reader.read();
    if (done) break;
    totalBytes += value.byteLength;
    if (totalBytes > maxBytes) {
      try { await reader.cancel(); } catch {}
      return null;
    }
    chunks.push(decoder.decode(value, {stream: true}));
  }
  chunks.push(decoder.decode());
  return chunks.join("");
}
function isIgnored(url, page, patterns) { return (patterns || []).some(pattern => wildcard(pattern, url) || wildcard(pattern, page)); }
function wildcard(pattern, value) { return wildcardMatch(pattern, value); }
function fileName(disposition, url) { return parseContentDispositionName(disposition, url); }
function isHTTP(value) { return isHttpUrl(value); }
