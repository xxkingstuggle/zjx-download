if (!window.__zjxContentInstalled) {
window.__zjxContentInstalled = true;
let lastSelection = "";
let selectionTimer;
let panel;
let candidateRenderTimer;
let errorToast;
let errorToastTimer;
let bypassKey = "Backspace";
let enabled = false;

chrome.runtime.sendMessage({type: "zjx-config"}).then(config => { if (config) bypassKey = config.bypassKey || "Backspace"; }).catch(() => {});
window.addEventListener("keydown", event => {
  if (matchesBypassKey(event, bypassKey)) chrome.runtime.sendMessage({type: "zjx-bypass", active: true});
}, true);
window.addEventListener("keyup", () => chrome.runtime.sendMessage({type: "zjx-bypass", active: false}), true);
window.addEventListener("blur", () => chrome.runtime.sendMessage({type: "zjx-bypass", active: false}), true);
window.addEventListener("mouseup", () => {
  if (!enabled) return;
  clearTimeout(selectionTimer);
  selectionTimer = setTimeout(() => {
    const text = window.getSelection()?.toString() || "";
    if (!text || text === lastSelection) return;
    lastSelection = text;
    const items = selectedLinks();
    if (items.length) chrome.runtime.sendMessage({type: "zjx-selection", items});
  }, 450);
});
chrome.runtime.onMessage.addListener(message => {
  if (message?.type === "zjx-selection-candidates") showSelectionButton(message.items);
  if (message?.type === "zjx-media-candidates") addCandidates(message.items);
  if (message?.type === "zjx-open-media") renderPanel();
  if (message?.type === "zjx-error") showError(message.message);
  if (message?.type === "zjx-config-updated") {
    bypassKey = message.config?.bypassKey || "Backspace";
    enabled = Boolean(message.config?.siteAccessGranted && (message.config?.autoCapture || message.config?.showPageWidgets));
    applyConfigToCandidates(message.config);
    window.__zjxConfig = message.config;
    if (!enabled || !message.config?.showPageWidgets) removePanel();
  }
});
function selectedLinks() {
  const selection = window.getSelection(); if (!selection || selection.isCollapsed) return [];
  const found = new Map();
  for (const anchor of document.querySelectorAll("a[href]")) {
    try {
      if ([...Array(selection.rangeCount).keys()].some(index => selection.getRangeAt(index).intersectsNode(anchor))) {
        const link = new URL(anchor.href, location.href).href;
        if (["http:", "https:"].includes(new URL(link).protocol) && !found.has(link)) found.set(link, {link, type: "http", description: anchor.textContent?.trim() || link, downloadPage: location.href});
      }
    } catch {}
  }
  return [...found.values()];
}
function showSelectionButton(items) {
  removePanel();
  const button = document.createElement("button"); button.textContent = `用 zjx-download 添加 ${items.length} 个链接`;
  Object.assign(button.style, {position: "fixed", zIndex: 2147483647, top: "18px", right: "18px", padding: "10px 14px", background: "#1769d2", color: "white", border: "0", borderRadius: "7px", boxShadow: "0 4px 15px #0005", cursor: "pointer"});
  button.addEventListener("mousedown", event => event.preventDefault());
  button.addEventListener("click", async () => {
    const result = await chrome.runtime.sendMessage({type: "zjx-submit", items});
    if (!result?.accepted || result.partial) showError(result?.message || result?.error || "App 未确认接收。");
    removePanel();
  });
  document.documentElement.append(button); panel = button;
}
function addCandidates(items) {
  const byLink = new Map((window.__zjxCandidates || []).map(item => [item.link, item]));
  for (const item of items) {
    if (item?.link) byLink.set(item.link, item);
  }
  window.__zjxCandidates = [...byLink.values()].slice(-30);
  if (window.__zjxConfig?.showPageWidgets !== false) scheduleCandidateRender();
}
function scheduleCandidateRender() {
  if (candidateRenderTimer) return;
  candidateRenderTimer = setTimeout(() => {
    candidateRenderTimer = undefined;
    void renderPanel();
  }, 250);
}
function stripCandidateHeaders(shouldStrip) {
  window.__zjxCandidates = (window.__zjxCandidates || []).map(item => {
    const headers = Object.fromEntries(Object.entries(item.headers || {}).filter(([name]) => !shouldStrip(name)));
    return {...item, headers};
  });
}
function isCookieHeader(name) { return String(name).toLowerCase() === "cookie"; }
function applyConfigToCandidates(config) {
  if (!config?.siteAccessGranted) window.__zjxCandidates = [];
  else if (!config?.sendRequestHeaders) stripCandidateHeaders(() => true);
  else if (config.cookiesPermissionGranted === false) stripCandidateHeaders(isCookieHeader);
}
async function renderPanel() {
  const config = await chrome.runtime.sendMessage({type: "zjx-config"});
  applyConfigToCandidates(config);
  window.__zjxConfig = config;
  enabled = Boolean(config?.siteAccessGranted && (config?.autoCapture || config?.showPageWidgets));
  const rows = window.__zjxCandidates || [];
  if (!enabled || !config?.showPageWidgets || !rows.length) return;
  removePanel();
  const box = document.createElement("div");
  Object.assign(box.style, {position: "fixed", zIndex: 2147483647, right: "16px", bottom: "16px", width: "min(400px, 85vw)", maxHeight: "45vh", overflow: "auto", padding: "12px", color: "#15202b", background: "#fff", border: "1px solid #ccd3dc", borderRadius: "9px", boxShadow: "0 4px 20px #0004", font: "13px -apple-system, BlinkMacSystemFont, sans-serif"});
  const header = document.createElement("div"); header.textContent = `媒体候选 (${rows.length})`; header.style.fontWeight = "600"; box.append(header);
  for (const item of rows) {
    const row = document.createElement("div"); row.style.cssText = "display:flex;gap:8px;align-items:center;margin-top:8px";
    const title = document.createElement("span"); title.textContent = item.suggestedName || item.description || new URL(item.link).pathname.split("/").pop(); title.style.cssText = "overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1";
    const button = document.createElement("button"); button.textContent = "添加"; button.addEventListener("click", async () => {
      const result = await chrome.runtime.sendMessage({type: "zjx-submit", items: [item]});
      if (!result?.accepted || result.partial) showError(result?.message || result?.error || "交接失败。");
    });
    row.append(title, button); box.append(row);
  }
  const close = document.createElement("button"); close.textContent = "关闭"; close.style.marginTop = "9px"; close.addEventListener("click", removePanel); box.append(close);
  document.documentElement.append(box); panel = box;
}
function showError(text) {
  if (!errorToast?.isConnected) {
    errorToast = document.createElement("div");
    Object.assign(errorToast.style, {position:"fixed",zIndex:2147483647,top:"16px",left:"50%",transform:"translateX(-50%)",maxWidth:"80vw",padding:"10px 14px",background:"#b42318",color:"white",borderRadius:"7px",font:"13px -apple-system, sans-serif"});
    document.documentElement.append(errorToast);
  }
  errorToast.textContent = String(text || "操作失败。").slice(0, 500);
  clearTimeout(errorToastTimer);
  errorToastTimer = setTimeout(() => { errorToast?.remove(); errorToast = undefined; errorToastTimer = undefined; }, 7000);
}
function removePanel() { clearTimeout(candidateRenderTimer); candidateRenderTimer = undefined; panel?.remove(); panel = undefined; }
function matchesBypassKey(event, shortcut) {
  const parts = String(shortcut || "Backspace").split("+").map(value => value.trim().toLowerCase()).filter(Boolean);
  if (!parts.length) return event.key === "Backspace";
  const aliases = {cmd: "meta", command: "meta", control: "ctrl", option: "alt", esc: "escape", spacebar: "space"};
  const normalized = parts.map(value => aliases[value] || value);
  const modifiers = {ctrl: event.ctrlKey, alt: event.altKey, shift: event.shiftKey, meta: event.metaKey};
  for (const modifier of Object.keys(modifiers)) {
    if (modifiers[modifier] !== normalized.includes(modifier)) return false;
  }
  const key = normalized.filter(value => !Object.hasOwn(modifiers, value));
  if (key.length !== 1) return false;
  const pressed = String(event.key || "").toLowerCase();
  const expected = key[0];
  return pressed === expected || String(event.code || "").toLowerCase() === expected;
}
}
