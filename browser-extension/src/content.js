if (!window.__zjxContentInstalled) {
window.__zjxContentInstalled = true;
let lastSelection = "";
let selectionTimer;
let candidateRenderTimer;
let toastTimer;
let bypassKey = "Backspace";
let bypassActive = false;
let enabled = false;
let currentConfig = null;
let shadowHost = null;
let shadowRoot = null;
let panelSlot = null;
let toastSlot = null;
let filterQuery = "";
let selectedLinksSet = new Set();

function applyConfig(config) {
  if (!config || typeof config !== "object") return;
  currentConfig = config;
  bypassKey = config.bypassKey || "Backspace";
  enabled = Boolean(config.siteAccessGranted && (config.autoCapture || config.showPageWidgets));
  applyConfigToCandidates(config);
  if (!enabled || !config.showPageWidgets) removePanel();
}

chrome.runtime.sendMessage({type: "zjx-config"}).then(applyConfig).catch(() => {});

function setBypassState(active) {
  if (bypassActive === active) return;
  bypassActive = active;
  chrome.runtime.sendMessage({type: "zjx-bypass", active}).catch(() => {});
}

window.addEventListener("keydown", event => {
  if (!bypassActive && matchesBypassKey(event, bypassKey)) setBypassState(true);
}, true);
window.addEventListener("keyup", () => {
  if (bypassActive) setBypassState(false);
}, true);
window.addEventListener("blur", () => {
  if (bypassActive) setBypassState(false);
}, true);
window.addEventListener("mouseup", () => {
  if (!enabled || currentConfig?.showPageWidgets === false) return;
  clearTimeout(selectionTimer);
  selectionTimer = setTimeout(() => {
    const text = window.getSelection()?.toString() || "";
    if (!text || text === lastSelection) return;
    lastSelection = text;
    const items = selectedLinks();
    if (items.length) chrome.runtime.sendMessage({type: "zjx-selection", items}).catch(() => {});
  }, 450);
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "zjx-selection-candidates") {
    showSelectionBar(message.items);
    return;
  }
  if (message?.type === "zjx-media-candidates") {
    addCandidates(message.items);
    return;
  }
  if (message?.type === "zjx-open-media") {
    if (Array.isArray(message.items) && message.items.length) {
      mergeCandidates(message.items);
    }
    renderPanel(true)
      .then(result => sendResponse(result))
      .catch(() => sendResponse({opened: false, count: (window.__zjxCandidates || []).length}));
    return true;
  }
  if (message?.type === "zjx-error") {
    showToast(message.message, "error");
    return;
  }
  if (message?.type === "zjx-config-updated") {
    applyConfig(message.config);
  }
});

function ensureShadowLayer() {
  if (shadowHost?.isConnected && shadowRoot && panelSlot && toastSlot) return;
  shadowHost = document.createElement("div");
  shadowHost.id = "zjx-download-overlay-root";
  Object.assign(shadowHost.style, {
    all: "initial",
    position: "fixed",
    inset: "0",
    zIndex: "2147483647",
    pointerEvents: "none"
  });
  shadowRoot = shadowHost.attachShadow({mode: "open"});
  const style = document.createElement("style");
  style.textContent = `
    :host {
      --surface: rgba(255, 255, 255, 0.92);
      --surface-soft: rgba(244, 246, 250, 0.9);
      --border: rgba(15, 23, 42, 0.12);
      --text: #111827;
      --muted: #5b6677;
      --accent: #0a66e8;
      --accent-hover: #0856c5;
      --accent-soft: rgba(10, 102, 232, 0.12);
      --hls: #6366f1;
      --hls-soft: rgba(99, 102, 241, 0.14);
      --danger: #d92d20;
      --success: #15803d;
      --shadow: 0 14px 36px rgba(15, 23, 42, 0.18), 0 2px 8px rgba(15, 23, 42, 0.08);
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Helvetica Neue", sans-serif;
      font-size: 13px;
      line-height: 1.4;
      color: var(--text);
    }
    @media (prefers-color-scheme: dark) {
      :host {
        --surface: rgba(28, 30, 36, 0.92);
        --surface-soft: rgba(42, 46, 56, 0.88);
        --border: rgba(255, 255, 255, 0.14);
        --text: #f3f4f6;
        --muted: #9ca3af;
        --accent: #3b82f6;
        --accent-hover: #2563eb;
        --accent-soft: rgba(59, 130, 246, 0.18);
        --hls: #818cf8;
        --hls-soft: rgba(129, 140, 248, 0.18);
        --danger: #ef4444;
        --success: #22c55e;
        --shadow: 0 16px 40px rgba(0, 0, 0, 0.45), 0 2px 10px rgba(0, 0, 0, 0.28);
      }
    }
    * { box-sizing: border-box; }
    .zjx-pill {
      pointer-events: auto;
      position: fixed;
      top: 18px;
      right: 18px;
      display: flex;
      align-items: center;
      gap: 10px;
      padding: 8px 10px 8px 14px;
      background: var(--surface);
      backdrop-filter: blur(18px) saturate(160%);
      -webkit-backdrop-filter: blur(18px) saturate(160%);
      border: 1px solid var(--border);
      border-radius: 12px;
      box-shadow: var(--shadow);
      color: var(--text);
    }
    .zjx-dot {
      width: 8px;
      height: 8px;
      border-radius: 999px;
      background: var(--accent);
      flex-shrink: 0;
    }
    .zjx-panel {
      pointer-events: auto;
      position: fixed;
      right: 18px;
      bottom: 18px;
      width: min(420px, calc(100vw - 36px));
      max-height: min(520px, 68vh);
      display: flex;
      flex-direction: column;
      background: var(--surface);
      backdrop-filter: blur(20px) saturate(165%);
      -webkit-backdrop-filter: blur(20px) saturate(165%);
      border: 1px solid var(--border);
      border-radius: 14px;
      box-shadow: var(--shadow);
      overflow: hidden;
    }
    .zjx-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
      padding: 12px 14px 10px;
      border-bottom: 1px solid var(--border);
    }
    .zjx-title {
      display: flex;
      align-items: center;
      gap: 8px;
      font-weight: 600;
      font-size: 13.5px;
    }
    .zjx-badge {
      font-size: 11px;
      font-weight: 600;
      font-variant-numeric: tabular-nums;
      padding: 1px 7px;
      border-radius: 999px;
      background: var(--accent-soft);
      color: var(--accent);
    }
    .zjx-toolbar {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 8px 12px;
      border-bottom: 1px solid var(--border);
      background: var(--surface-soft);
    }
    .zjx-input {
      flex: 1;
      min-width: 0;
      padding: 6px 9px;
      border-radius: 8px;
      border: 1px solid var(--border);
      background: var(--surface);
      color: var(--text);
      font: inherit;
      font-size: 12.5px;
      outline: none;
    }
    .zjx-input:focus { border-color: var(--accent); }
    .zjx-list {
      overflow-y: auto;
      padding: 6px 8px;
      display: flex;
      flex-direction: column;
      gap: 4px;
    }
    .zjx-row {
      display: flex;
      align-items: center;
      gap: 8px;
      padding: 7px 8px;
      border-radius: 9px;
      border: 1px solid transparent;
      transition: background 0.14s ease, border-color 0.14s ease;
    }
    .zjx-row:hover {
      background: var(--surface-soft);
      border-color: var(--border);
    }
    .zjx-check {
      width: 15px;
      height: 15px;
      accent-color: var(--accent);
      cursor: pointer;
      flex-shrink: 0;
    }
    .zjx-meta {
      flex: 1;
      min-width: 0;
      display: flex;
      flex-direction: column;
      gap: 2px;
    }
    .zjx-name-row {
      display: flex;
      align-items: center;
      gap: 6px;
      min-width: 0;
    }
    .zjx-name {
      font-weight: 500;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .zjx-sub {
      font-size: 11px;
      color: var(--muted);
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }
    .zjx-tag {
      font-size: 10px;
      font-weight: 700;
      letter-spacing: 0.03em;
      padding: 1px 5px;
      border-radius: 5px;
      flex-shrink: 0;
    }
    .zjx-tag.hls { background: var(--hls-soft); color: var(--hls); }
    .zjx-tag.http { background: var(--accent-soft); color: var(--accent); }
    .zjx-foot {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
      padding: 10px 12px;
      border-top: 1px solid var(--border);
      background: var(--surface-soft);
    }
    .zjx-btn {
      border: 0;
      border-radius: 8px;
      padding: 6px 11px;
      font: inherit;
      font-size: 12px;
      font-weight: 500;
      cursor: pointer;
      transition: background 0.14s ease, opacity 0.14s ease;
      white-space: nowrap;
    }
    .zjx-btn:disabled { opacity: 0.45; cursor: not-allowed; }
    .zjx-btn.primary { background: var(--accent); color: #fff; }
    .zjx-btn.primary:hover:not(:disabled) { background: var(--accent-hover); }
    .zjx-btn.ghost { background: transparent; color: var(--muted); padding: 4px 8px; }
    .zjx-btn.ghost:hover:not(:disabled) { background: var(--border); color: var(--text); }
    .zjx-btn.subtle { background: var(--surface); border: 1px solid var(--border); color: var(--text); }
    .zjx-btn.subtle:hover:not(:disabled) { border-color: var(--accent); color: var(--accent); }
    .zjx-empty {
      padding: 20px 12px;
      text-align: center;
      color: var(--muted);
      font-size: 12px;
    }
    .zjx-toast {
      pointer-events: auto;
      position: fixed;
      top: 18px;
      left: 50%;
      transform: translateX(-50%);
      max-width: min(460px, calc(100vw - 32px));
      padding: 9px 14px;
      border-radius: 10px;
      color: #fff;
      font-weight: 500;
      box-shadow: var(--shadow);
    }
    .zjx-toast.error { background: var(--danger); }
    .zjx-toast.success { background: var(--success); }
  `;
  panelSlot = document.createElement("div");
  toastSlot = document.createElement("div");
  shadowRoot.append(style, panelSlot, toastSlot);
  document.documentElement.append(shadowHost);
}

function cleanupShadowHostIfEmpty() {
  if (!shadowHost) return;
  if ((!panelSlot || panelSlot.childElementCount === 0) && (!toastSlot || toastSlot.childElementCount === 0)) {
    shadowHost.remove();
    shadowHost = null;
    shadowRoot = null;
    panelSlot = null;
    toastSlot = null;
  }
}

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

function showSelectionBar(items) {
  if (!Array.isArray(items) || !items.length) return;
  removePanel();
  ensureShadowLayer();
  const pill = document.createElement("div");
  pill.className = "zjx-pill";
  const dot = document.createElement("span");
  dot.className = "zjx-dot";
  const label = document.createElement("span");
  label.textContent = `已选中 ${items.length} 个链接`;
  const addBtn = document.createElement("button");
  addBtn.className = "zjx-btn primary";
  addBtn.textContent = "发送到 zjx-download";
  addBtn.addEventListener("mousedown", event => event.preventDefault());
  addBtn.addEventListener("click", async () => {
    addBtn.disabled = true;
    addBtn.textContent = "发送中…";
    const result = await chrome.runtime.sendMessage({type: "zjx-submit", items}).catch(err => ({accepted: false, error: err?.message}));
    if (!result?.accepted || result.partial) showToast(result?.message || result?.error || "App 未确认接收。", "error");
    else showToast(`已发送 ${result.acceptedCount} 个链接到 zjx-download`, "success");
    removePanel();
  });
  const closeBtn = document.createElement("button");
  closeBtn.className = "zjx-btn ghost";
  closeBtn.textContent = "×";
  closeBtn.title = "关闭";
  closeBtn.addEventListener("click", removePanel);
  pill.append(dot, label, addBtn, closeBtn);
  panelSlot.replaceChildren(pill);
}

function mergeCandidates(items) {
  const byLink = new Map((window.__zjxCandidates || []).map(item => [item.link, item]));
  for (const item of items) {
    if (item?.link) byLink.set(item.link, item);
  }
  window.__zjxCandidates = [...byLink.values()].slice(-30);
}

function addCandidates(items) {
  mergeCandidates(items);
  if (currentConfig?.showPageWidgets !== false) scheduleCandidateRender();
}
function scheduleCandidateRender() {
  if (candidateRenderTimer) return;
  candidateRenderTimer = setTimeout(() => {
    candidateRenderTimer = undefined;
    void renderPanel(false);
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

function candidateDisplayName(item) {
  if (item.suggestedName) return item.suggestedName;
  if (item.description) return item.description;
  try { return decodeURIComponent(new URL(item.link).pathname.split("/").pop() || item.link); }
  catch { return item.link; }
}

function candidateSubline(item) {
  const parts = [];
  if (item.description && item.description !== item.suggestedName) parts.push(item.description);
  try { parts.push(new URL(item.link).host); } catch {}
  return parts.join(" · ") || item.link;
}

async function renderPanel(forceOpen = false) {
  const config = await chrome.runtime.sendMessage({type: "zjx-config"}).catch(() => currentConfig);
  if (config) applyConfig(config);
  const rows = window.__zjxCandidates || [];
  if (!enabled || (!forceOpen && !currentConfig?.showPageWidgets) || !rows.length) {
    return {opened: false, count: rows.length};
  }
  const validLinks = new Set(rows.map(item => item.link));
  selectedLinksSet = new Set([...selectedLinksSet].filter(link => validLinks.has(link)));
  if (selectedLinksSet.size === 0) {
    for (const item of rows) selectedLinksSet.add(item.link);
  }
  removePanel();
  ensureShadowLayer();

  const box = document.createElement("div");
  box.className = "zjx-panel";

  const header = document.createElement("div");
  header.className = "zjx-head";
  const titleWrap = document.createElement("div");
  titleWrap.className = "zjx-title";
  const dot = document.createElement("span");
  dot.className = "zjx-dot";
  const titleText = document.createElement("span");
  titleText.textContent = "媒体候选";
  const badge = document.createElement("span");
  badge.className = "zjx-badge";
  badge.textContent = String(rows.length);
  titleWrap.append(dot, titleText, badge);
  const closeBtn = document.createElement("button");
  closeBtn.className = "zjx-btn ghost";
  closeBtn.textContent = "×";
  closeBtn.title = "关闭";
  closeBtn.addEventListener("click", removePanel);
  header.append(titleWrap, closeBtn);

  const toolbar = document.createElement("div");
  toolbar.className = "zjx-toolbar";
  const searchInput = document.createElement("input");
  searchInput.className = "zjx-input";
  searchInput.type = "search";
  searchInput.placeholder = "筛选文件名或地址…";
  searchInput.value = filterQuery;
  const toggleAllBtn = document.createElement("button");
  toggleAllBtn.className = "zjx-btn subtle";
  toolbar.append(searchInput, toggleAllBtn);

  const list = document.createElement("div");
  list.className = "zjx-list";

  const footer = document.createElement("div");
  footer.className = "zjx-foot";
  const selectionInfo = document.createElement("span");
  selectionInfo.className = "zjx-sub";
  const submitSelectedBtn = document.createElement("button");
  submitSelectedBtn.className = "zjx-btn primary";
  footer.append(selectionInfo, submitSelectedBtn);

  function filteredRows() {
    const q = filterQuery.trim().toLowerCase();
    if (!q) return rows;
    return rows.filter(item =>
      candidateDisplayName(item).toLowerCase().includes(q) ||
      item.link.toLowerCase().includes(q) ||
      String(item.description || "").toLowerCase().includes(q)
    );
  }

  function syncFooter(visible) {
    const selectedVisible = visible.filter(item => selectedLinksSet.has(item.link));
    const allSelected = visible.length > 0 && selectedVisible.length === visible.length;
    toggleAllBtn.textContent = allSelected ? "取消全选" : "全选";
    toggleAllBtn.disabled = visible.length === 0;
    const totalSelected = rows.filter(item => selectedLinksSet.has(item.link)).length;
    selectionInfo.textContent = `已选 ${totalSelected} / ${rows.length} 项`;
    submitSelectedBtn.textContent = `添加已选 (${totalSelected})`;
    submitSelectedBtn.disabled = totalSelected === 0;
  }

  function renderList() {
    const visible = filteredRows();
    list.replaceChildren();
    if (!visible.length) {
      const empty = document.createElement("div");
      empty.className = "zjx-empty";
      empty.textContent = "没有匹配的媒体项";
      list.append(empty);
      syncFooter(visible);
      return;
    }
    for (const item of visible) {
      const row = document.createElement("div");
      row.className = "zjx-row";
      const check = document.createElement("input");
      check.className = "zjx-check";
      check.type = "checkbox";
      check.checked = selectedLinksSet.has(item.link);
      check.addEventListener("change", () => {
        if (check.checked) selectedLinksSet.add(item.link);
        else selectedLinksSet.delete(item.link);
        syncFooter(visible);
      });

      const meta = document.createElement("div");
      meta.className = "zjx-meta";
      const nameRow = document.createElement("div");
      nameRow.className = "zjx-name-row";
      const tag = document.createElement("span");
      const isHLS = item.type === "hls";
      tag.className = `zjx-tag ${isHLS ? "hls" : "http"}`;
      tag.textContent = isHLS ? "HLS" : "HTTP";
      const nameEl = document.createElement("span");
      nameEl.className = "zjx-name";
      nameEl.textContent = candidateDisplayName(item);
      nameEl.title = item.link;
      nameRow.append(tag, nameEl);
      const sub = document.createElement("span");
      sub.className = "zjx-sub";
      sub.textContent = candidateSubline(item);
      sub.title = item.link;
      meta.append(nameRow, sub);

      const addOne = document.createElement("button");
      addOne.className = "zjx-btn subtle";
      addOne.textContent = "添加";
      addOne.addEventListener("click", async () => {
        addOne.disabled = true;
        addOne.textContent = "发送中…";
        const result = await chrome.runtime.sendMessage({type: "zjx-submit", items: [item]}).catch(err => ({accepted: false, error: err?.message}));
        if (!result?.accepted || result.partial) {
          addOne.disabled = false;
          addOne.textContent = "添加";
          showToast(result?.message || result?.error || "交接失败。", "error");
        } else {
          addOne.textContent = "已添加";
          showToast("已发送到 zjx-download", "success");
        }
      });
      row.append(check, meta, addOne);
      list.append(row);
    }
    syncFooter(visible);
  }

  searchInput.addEventListener("input", () => {
    filterQuery = searchInput.value;
    renderList();
  });
  toggleAllBtn.addEventListener("click", () => {
    const visible = filteredRows();
    const allSelected = visible.length > 0 && visible.every(item => selectedLinksSet.has(item.link));
    for (const item of visible) {
      if (allSelected) selectedLinksSet.delete(item.link);
      else selectedLinksSet.add(item.link);
    }
    renderList();
  });
  submitSelectedBtn.addEventListener("click", async () => {
    const targets = rows.filter(item => selectedLinksSet.has(item.link));
    if (!targets.length) return;
    submitSelectedBtn.disabled = true;
    submitSelectedBtn.textContent = "发送中…";
    const result = await chrome.runtime.sendMessage({type: "zjx-submit", items: targets}).catch(err => ({accepted: false, error: err?.message}));
    if (!result?.accepted || result.partial) {
      showToast(result?.message || result?.error || "部分或全部项交接失败。", "error");
      renderList();
    } else {
      showToast(`已发送 ${result.acceptedCount} 项到 zjx-download`, "success");
      removePanel();
    }
  });

  renderList();
  box.append(header, toolbar, list, footer);
  panelSlot.replaceChildren(box);
  return {opened: true, count: rows.length};
}

function showToast(text, kind = "error") {
  ensureShadowLayer();
  const el = document.createElement("div");
  el.className = `zjx-toast ${kind}`;
  el.textContent = String(text || "操作失败。").slice(0, 500);
  toastSlot.replaceChildren(el);
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    toastSlot?.replaceChildren();
    toastTimer = undefined;
    cleanupShadowHostIfEmpty();
  }, kind === "success" ? 3200 : 6500);
}

function removePanel() {
  clearTimeout(candidateRenderTimer);
  candidateRenderTimer = undefined;
  panelSlot?.replaceChildren();
  cleanupShadowHostIfEmpty();
}

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
  if (key.length === 0) return normalized.length > 0;
  if (key.length !== 1) return false;
  const pressed = String(event.key || "").toLowerCase();
  const expected = key[0];
  return pressed === expected || String(event.code || "").toLowerCase() === expected;
}
}
