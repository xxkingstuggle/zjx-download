import {controlTask, fetchStatus, fetchTasks, ping, saveExtensionSettings} from "./app-api.js";
import {saveConfig} from "./storage.js";
import {formatBytes, formatEta, formatSpeed, isHttpUrl} from "./utils.js";

const STATUS_LABELS = {
  downloading: "下载中",
  preparing: "准备中",
  queued: "等待中",
  paused: "已暂停",
  completed: "已完成",
  failed: "失败",
  cancelled: "已取消"
};

const statusDot = document.getElementById("statusDot");
const connectionEl = document.getElementById("connection");
const versionTag = document.getElementById("versionTag");
const authBanner = document.getElementById("authBanner");
const quickForm = document.getElementById("quickForm");
const quickUrl = document.getElementById("quickUrl");
const quickSubmit = document.getElementById("quickSubmit");
const tasksHeader = document.getElementById("tasksHeader");
const aggregateSpeedEl = document.getElementById("aggregateSpeed");
const taskListEl = document.getElementById("taskList");
const mediaCountBadge = document.getElementById("mediaCountBadge");
const messageEl = document.getElementById("message");

let pollTimer = null;
let isConnected = false;
let activeTab = null;
let currentConfig = {};

try {
  const manifest = chrome.runtime.getManifest();
  if (manifest?.version) versionTag.textContent = `v${manifest.version}`;
} catch {}

function setMessage(text, tone = "neutral") {
  messageEl.textContent = text;
  messageEl.dataset.tone = tone;
}

function renderConnection(pingResult, statusResult, config) {
  const unauthorized = Boolean(pingResult?.unauthorized || statusResult?.unauthorized || (config?.apiRequiresKey && !config?.apiKey));
  authBanner.hidden = !unauthorized;
  if (pingResult?.connected) {
    isConnected = true;
    statusDot.className = "dot online";
    const portLabel = statusResult?.status?.listeningPort ? ` :${statusResult.status.listeningPort}` : "";
    connectionEl.textContent = `已连接 · ${pingResult.channel}${portLabel}`;
  } else if (unauthorized) {
    isConnected = false;
    statusDot.className = "dot warn";
    connectionEl.textContent = "鉴权失败 · 需检查 API Key";
  } else {
    isConnected = false;
    statusDot.className = "dot offline";
    connectionEl.textContent = "App 未连接";
  }
}

function pickDisplayTasks(tasks) {
  const priority = {downloading: 0, preparing: 1, queued: 2, paused: 3, failed: 4, completed: 5, cancelled: 6};
  return [...tasks]
    .sort((a, b) => {
      const pa = priority[a.status] ?? 9;
      const pb = priority[b.status] ?? 9;
      if (pa !== pb) return pa - pb;
      return String(b.createdAt || "").localeCompare(String(a.createdAt || ""));
    })
    .slice(0, 4);
}

function renderTasks(tasksResponse, statusData) {
  const activeSpeed = statusData?.aggregateSpeedBytesPerSecond || 0;
  if (activeSpeed > 0) {
    aggregateSpeedEl.textContent = formatSpeed(activeSpeed);
    aggregateSpeedEl.hidden = false;
  } else {
    aggregateSpeedEl.hidden = true;
  }

  if (!tasksResponse?.ok) {
    tasksHeader.textContent = "活跃下载";
    taskListEl.replaceChildren();
    const empty = document.createElement("div");
    empty.className = "empty-state";
    empty.textContent = tasksResponse?.unauthorized
      ? "请在设置中填写与 App 一致的 API Key 以查看实时进度。"
      : "连接本机 zjx-download 后可在此查看实时下载进度。";
    taskListEl.append(empty);
    return;
  }

  const allTasks = tasksResponse.tasks || [];
  const activeCount = allTasks.filter(t => t.status === "downloading" || t.status === "preparing").length;
  tasksHeader.textContent = activeCount > 0 ? `活跃下载 (${activeCount})` : `最近任务 (${allTasks.length})`;

  const visible = pickDisplayTasks(allTasks);
  taskListEl.replaceChildren();
  if (!visible.length) {
    const empty = document.createElement("div");
    empty.className = "empty-state";
    empty.textContent = "暂无下载任务，可在上方粘贴链接快捷投递。";
    taskListEl.append(empty);
    return;
  }

  for (const task of visible) {
    const item = document.createElement("div");
    item.className = "task-item";

    const top = document.createElement("div");
    top.className = "task-top";
    const name = document.createElement("span");
    name.className = "task-name";
    name.textContent = task.name || task.link;
    name.title = task.name || task.link;
    top.append(name);

    const isActive = task.status === "downloading" || task.status === "preparing";
    const canResume = task.status === "paused" || task.status === "failed" || task.status === "queued";
    if (isActive || canResume) {
      const actionBtn = document.createElement("button");
      actionBtn.className = "mini-btn";
      actionBtn.type = "button";
      actionBtn.textContent = isActive ? "暂停" : "继续";
      actionBtn.addEventListener("click", async () => {
        actionBtn.disabled = true;
        const res = await controlTask(task.id, isActive ? "pause" : "resume");
        if (!res.ok) setMessage(res.error || "任务操作失败。", "error");
        await refreshLiveState();
      });
      top.append(actionBtn);
    }

    const track = document.createElement("div");
    track.className = "task-track";
    const fill = document.createElement("div");
    fill.className = `task-fill ${task.status || ""}`;
    const ratio = typeof task.progress === "number" && Number.isFinite(task.progress)
      ? Math.min(100, Math.max(0, Math.round(task.progress * 100)))
      : (task.status === "completed" ? 100 : 0);
    fill.style.width = `${ratio}%`;
    track.append(fill);

    const meta = document.createElement("div");
    meta.className = "task-meta tabular";
    const leftMeta = document.createElement("span");
    const statusLabel = STATUS_LABELS[task.status] || task.status || "";
    const sizeText = task.totalBytes > 0
      ? `${ratio}% · ${formatBytes(task.receivedBytes)} / ${formatBytes(task.totalBytes)}`
      : formatBytes(task.receivedBytes || 0);
    leftMeta.textContent = `${statusLabel} · ${sizeText}`;

    const rightMeta = document.createElement("span");
    if (isActive && task.speedBytesPerSecond > 0) {
      const eta = task.etaSeconds > 0 ? ` · ${formatEta(task.etaSeconds)}` : "";
      rightMeta.textContent = `${formatSpeed(task.speedBytesPerSecond)}${eta}`;
    } else {
      rightMeta.textContent = task.kind === "hls" ? "HLS" : "";
    }
    meta.append(leftMeta, rightMeta);
    item.append(top, track, meta);
    taskListEl.append(item);
  }
}

async function refreshTabMediaCount() {
  const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
  activeTab = tab || null;
  if (tab?.id == null) {
    mediaCountBadge.dataset.empty = "true";
    return;
  }
  const res = await chrome.runtime.sendMessage({type: "zjx-tab-media-count", tabId: tab.id}).catch(() => ({count: 0}));
  const count = Number(res?.count || 0);
  mediaCountBadge.textContent = String(count);
  mediaCountBadge.dataset.empty = count > 0 ? "false" : "true";
}

async function refreshLiveState() {
  const [pingResult, statusResult, tasksResponse] = await Promise.all([
    ping(),
    fetchStatus(),
    fetchTasks()
  ]);
  renderConnection(pingResult, statusResult, currentConfig);
  renderTasks(tasksResponse, statusResult?.status);
}

async function requestCapturePermissions() {
  const permissions = ["webRequest"];
  const origins = ["http://*/*", "https://*/*"];
  const granted = await chrome.permissions.request({permissions, origins});
  if (!granted) {
    setMessage("需要网站访问与 webRequest 权限才能发现媒体或自动接管。", "error");
    return false;
  }
  await saveConfig({siteAccessGranted: true});
  return true;
}

const config = await chrome.runtime.sendMessage({type: "zjx-config"}).catch(() => null) || {};
currentConfig = config;
for (const key of ["autoCapture", "showPageWidgets", "silentAdd"]) {
  const input = document.getElementById(key);
  input.checked = Boolean(config[key]);
  input.addEventListener("change", async () => {
    const patch = {[key]: input.checked};
    if ((key === "autoCapture" || key === "showPageWidgets") && input.checked && !await requestCapturePermissions()) {
      input.checked = false;
      return;
    }
    const {synced} = await saveExtensionSettings(patch);
    currentConfig = {...currentConfig, ...patch};
    setMessage(synced ? "设置已同步到 App。" : "已保存到 Chrome；App 当前离线或未确认同步。", synced ? "success" : "neutral");
  });
}

quickForm.addEventListener("submit", async event => {
  event.preventDefault();
  const link = quickUrl.value.trim();
  if (!isHttpUrl(link)) {
    setMessage("请输入有效的 HTTP 或 HTTPS 下载链接。", "error");
    quickUrl.focus();
    return;
  }
  quickSubmit.disabled = true;
  quickSubmit.textContent = "发送中…";
  try {
    const result = await chrome.runtime.sendMessage({
      type: "zjx-submit",
      items: [{link, type: "http", downloadPage: activeTab?.url || ""}]
    });
    if (result?.accepted) {
      quickUrl.value = "";
      setMessage(`已添加任务 #${result.acceptedTaskIDs?.[0] ?? ""}。`, "success");
      await refreshLiveState();
    } else {
      setMessage(result?.message || result?.error || "App 未确认接收此链接。", "error");
    }
  } catch (error) {
    setMessage(error?.message || "投递失败。", "error");
  } finally {
    quickSubmit.disabled = false;
    quickSubmit.textContent = "添加";
  }
});

document.getElementById("settings").addEventListener("click", () => chrome.runtime.openOptionsPage());
document.getElementById("authSettingsBtn").addEventListener("click", () => chrome.runtime.openOptionsPage());
document.getElementById("refreshBtn").addEventListener("click", async () => {
  await Promise.all([refreshLiveState(), refreshTabMediaCount()]);
  setMessage("已刷新状态。", "neutral");
});
document.getElementById("pageMedia").addEventListener("click", async () => {
  const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
  if (tab?.id == null) {
    setMessage("找不到当前标签页。", "error");
    return;
  }
  const res = await chrome.runtime.sendMessage({type: "zjx-show-candidates", tabId: tab.id}).catch(err => ({shown: false, reason: err?.message}));
  if (res?.shown) {
    setMessage(`已在页面打开媒体候选面板（${res.count} 项）。`, "success");
  } else {
    setMessage(res?.reason || "当前页面暂未发现媒体候选。", "error");
  }
});

await Promise.all([refreshLiveState(config), refreshTabMediaCount()]);
pollTimer = setInterval(() => {
  if (isConnected) void refreshLiveState();
}, 1500);
window.addEventListener("pagehide", () => {
  if (pollTimer) clearInterval(pollTimer);
});
