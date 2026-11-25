import {getConfig, saveConfig} from "./storage.js";
import {computeRequestDeadlineMs} from "./utils.js";

const requestId = () => crypto.randomUUID();
const MAX_REQUEST_WAIT_MS = 120_000;

export async function ping() {
  const config = await getConfig();
  try {
    const response = await fetch(`http://127.0.0.1:${config.port}/ping`, {method: "POST", headers: headers(config), body: "", signal: AbortSignal.timeout(1800)});
    if (response.ok && (await response.text()).trim() === "pong") return {connected: true, channel: "HTTP", unauthorized: false};
    if (response.status === 401) return {connected: false, channel: "HTTP", unauthorized: true};
  } catch {}
  const id = requestId();
  try {
    const response = await chrome.runtime.sendNativeMessage("com.zjx.download", {id, content: {action: "ping", payload: JSON.stringify({requestId: id, options: {apiPort: config.port, apiKey: config.apiKey}})}});
    if (response?.id === id && response?.content?.isError === false && response?.content?.payload === "pong") {
      return {connected: true, channel: "Native Messaging", unauthorized: false};
    }
    if (typeof response?.content?.payload === "string" && response.content.payload.includes("UNAUTHORIZED")) {
      return {connected: false, channel: "Native Messaging", unauthorized: true};
    }
  } catch { return {connected: false, channel: "", unauthorized: false}; }
  return {connected: false, channel: "", unauthorized: false};
}

export async function fetchStatus() {
  const config = await getConfig();
  try {
    const response = await fetch(`http://127.0.0.1:${config.port}/status`, {
      method: "GET", headers: authHeaders(config), signal: AbortSignal.timeout(1800)
    });
    if (response.status === 401) return {ok: false, unauthorized: true, status: null};
    if (!response.ok) return {ok: false, unauthorized: false, status: null};
    const value = await response.json();
    if (value && typeof value === "object") return {ok: true, unauthorized: false, status: value};
    return {ok: false, unauthorized: false, status: null};
  } catch {
    return {ok: false, unauthorized: false, status: null};
  }
}

export async function fetchTasks() {
  const config = await getConfig();
  try {
    const response = await fetch(`http://127.0.0.1:${config.port}/tasks`, {
      method: "GET", headers: authHeaders(config), signal: AbortSignal.timeout(2200)
    });
    if (response.status === 401) return {ok: false, unauthorized: true, tasks: [], error: "需要有效的 API Key。"};
    if (!response.ok) return {ok: false, unauthorized: false, tasks: [], error: `HTTP ${response.status}`};
    const value = await response.json();
    return {ok: true, unauthorized: false, tasks: Array.isArray(value) ? value : []};
  } catch (error) {
    return {ok: false, unauthorized: false, tasks: [], error: error?.message || "无法连接本机 App。"};
  }
}

export async function controlTask(taskId, action) {
  const numericId = Number(taskId);
  const allowed = new Set(["start", "resume", "pause", "cancel", "remove"]);
  if (!Number.isSafeInteger(numericId) || numericId <= 0 || !allowed.has(action)) {
    return {ok: false, error: "无效的任务操作参数。"};
  }
  const config = await getConfig();
  const method = action === "remove" ? "DELETE" : "POST";
  try {
    const response = await fetch(`http://127.0.0.1:${config.port}/tasks/${numericId}/${action}`, {
      method, headers: headers(config), body: "", signal: AbortSignal.timeout(3000)
    });
    if (response.status === 401) return {ok: false, unauthorized: true, error: "缺少或错误的 API Key。"};
    if (!response.ok) {
      const text = await response.text().catch(() => "");
      return {ok: false, error: safeBody(text) || `HTTP ${response.status}`};
    }
    return {ok: true};
  } catch (error) {
    return {ok: false, error: error?.message || "操作失败。"};
  }
}

export async function fetchExtensionSettings() {
  const config = await getConfig();
  try {
    const response = await fetch(`http://127.0.0.1:${config.port}/settings/extension`, {
      method: "GET", headers: authHeaders(config), signal: AbortSignal.timeout(1500)
    });
    if (!response.ok) return null;
    const value = await response.json();
    return value && typeof value === "object" ? value : null;
  } catch { return null; }
}

export async function saveExtensionSettings(patch) {
  const config = await getConfig();
  const keys = ["autoCapture", "showPageWidgets", "sendRequestHeaders", "silentAdd", "silentStart",
    "closeCapturedTab", "bypassKey", "minimumSizeKB", "extensions", "ignoredPatterns"];
  const payload = Object.fromEntries(keys.filter(key => Object.hasOwn(patch, key)).map(key => [key, patch[key]]));
  let synced = false;
  try {
    const response = await fetch(`http://127.0.0.1:${config.port}/settings/extension`, {
      method: "PUT", headers: headers(config), body: JSON.stringify(payload), signal: AbortSignal.timeout(2500)
    });
    synced = response.ok;
  } catch {}
  await saveConfig(patch);
  return {synced};
}

export async function sendItems(items, {silentStart = false, requestID = requestId(), timeoutMs = MAX_REQUEST_WAIT_MS} = {}) {
  if (!Array.isArray(items) || items.length === 0) throw new Error("没有可发送的下载请求。");
  if (typeof requestID !== "string" || requestID.length < 1 || requestID.length > 128) throw new Error("请求编号无效。");
  const waitLimit = Number.isFinite(timeoutMs) ? Math.max(1, Math.min(MAX_REQUEST_WAIT_MS, timeoutMs)) : MAX_REQUEST_WAIT_MS;
  const now = Date.now();
  const deadline = now + waitLimit;
  const remaining = () => Math.max(0, deadline - Date.now());
  const config = await awaitWithin(getConfig(), remaining(), "读取扩展设置超时。");
  const options = {
    silentAdd: config.silentAdd,
    silentStart: Boolean(config.silentAdd && silentStart),
    requestDeadlineMs: computeRequestDeadlineMs(now, waitLimit)
  };
  const payload = {requestId: requestID, items, options};
  const nativePayload = {requestId: requestID, items, options: {...options, apiPort: config.port, apiKey: config.apiKey}};
  let httpError = new Error("HTTP 请求未能确认接收。");
  try {
    const httpWait = remaining();
    if (httpWait <= 0) throw new Error("请求等待时间已用完。");
    const response = await fetch(`http://127.0.0.1:${config.port}/add`, {
      method: "POST", headers: headers(config), body: JSON.stringify(payload), signal: AbortSignal.timeout(httpWait)
    });
    const text = await response.text();
    if (!response.ok) throw new Error(`App returned ${response.status}: ${safeBody(text)}`);
    return {...decodeAcceptance(text, requestID, items.length), channel: "HTTP"};
  } catch (error) { httpError = error; }
  try {
    const nativeWait = remaining();
    if (nativeWait <= 0) throw new Error("请求等待时间已用完。");
    const nativeMessage = chrome.runtime.sendNativeMessage("com.zjx.download", {
      id: requestID, content: {action: "add", payload: JSON.stringify(nativePayload)}
    });
    let timeout;
    const response = await Promise.race([
      nativeMessage,
      new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error("Native Messaging 等待超时。")), nativeWait); })
    ]).finally(() => clearTimeout(timeout));
    const content = response?.content;
    if (response?.id !== requestID || !content || content.isError !== false) {
      throw new Error(content?.payload || "Native Messaging 未确认接收。");
    }
    return {...decodeAcceptance(content.payload, requestID, items.length), channel: "Native Messaging"};
  } catch (nativeError) {
    throw new Error(`App 未确认接收。HTTP: ${httpError?.message || "失败"}；Native Messaging: ${nativeError?.message || String(nativeError)}`);
  }
}

export function decodeAcceptance(value, expectedRequestID, expectedItemCount) {
  let result;
  try {
    result = typeof value === "string" ? JSON.parse(value) : value;
  } catch { throw new Error("App 返回的接收结果不是有效 JSON。"); }
  if (!result || typeof result !== "object" || Array.isArray(result)) throw new Error("App 未返回可核验的接收结果。");
  if (result.requestId !== expectedRequestID) throw new Error("App 返回了不匹配的请求编号。");
  if (!Array.isArray(result.items) || result.items.length !== expectedItemCount) throw new Error("App 返回的逐项接收结果不完整。");
  if (!Array.isArray(result.acceptedTaskIDs)) throw new Error("App 返回的任务编号列表无效。");
  if (!Number.isSafeInteger(result.acceptedCount) || result.acceptedCount < 0 || result.acceptedCount > expectedItemCount) {
    throw new Error("App 返回的接收数量无效。");
  }

  const itemsByIndex = new Array(expectedItemCount);
  for (const item of result.items) {
    if (!item || typeof item !== "object" || !Number.isSafeInteger(item.index) || item.index < 0 || item.index >= expectedItemCount || itemsByIndex[item.index]) {
      throw new Error("App 返回的逐项索引无效或重复。");
    }
    const hasTaskID = item.taskID !== undefined && item.taskID !== null;
    if (hasTaskID) {
      if (!Number.isSafeInteger(item.taskID) || item.taskID <= 0 || ("error" in item && item.error != null)) {
        throw new Error("App 返回的任务编号与错误状态不一致。");
      }
    } else if (typeof item.error !== "string" || item.error.trim().length === 0) {
      throw new Error("App 未说明某项为何没有被接收。");
    }
    itemsByIndex[item.index] = {index: item.index, taskID: hasTaskID ? item.taskID : null, error: hasTaskID ? null : item.error};
  }
  for (let index = 0; index < expectedItemCount; index++) {
    if (itemsByIndex[index] === undefined) throw new Error("App 返回的逐项索引不完整。");
  }

  const taskIDs = itemsByIndex.filter(item => item.taskID !== null).map(item => item.taskID);
  if (new Set(taskIDs).size !== taskIDs.length || result.acceptedTaskIDs.some(id => !Number.isSafeInteger(id) || id <= 0)) {
    throw new Error("App 返回了重复或不可精确表示的任务编号。");
  }
  if (result.acceptedTaskIDs.length !== taskIDs.length || result.acceptedTaskIDs.some((id, index) => id !== taskIDs[index])) {
    throw new Error("App 返回的任务编号与逐项接收结果不一致。");
  }
  if (result.acceptedCount !== taskIDs.length || result.accepted !== (taskIDs.length > 0)) {
    throw new Error("App 返回的接收状态与接收数量不一致。");
  }
  if (result.declined !== undefined && typeof result.declined !== "boolean") throw new Error("App 返回的拒绝状态无效。");
  if (result.declined === true && taskIDs.length > 0) throw new Error("App 同时报告拒绝和接收成功。");

  return {
    requestId: expectedRequestID,
    accepted: taskIDs.length > 0,
    acceptedCount: taskIDs.length,
    acceptedTaskIDs: taskIDs,
    items: itemsByIndex,
    declined: result.declined === true
  };
}

function headers(config) {
  const value = {"Content-Type": "application/json"};
  if (config.apiKey) value["X-API-Key"] = config.apiKey;
  return value;
}
function authHeaders(config) {
  const value = {};
  if (config.apiKey) value["X-API-Key"] = config.apiKey;
  return value;
}
function safeBody(text) { return text.slice(0, 300).replace(/[\r\n]+/g, " "); }
async function awaitWithin(promise, milliseconds, message) {
  if (milliseconds <= 0) throw new Error(message);
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(message)), milliseconds); })
    ]);
  } finally { clearTimeout(timer); }
}
