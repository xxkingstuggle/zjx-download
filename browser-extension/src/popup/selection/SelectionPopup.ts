import { PositionInPage } from "~/utils/MouseUtil";
import browser from "webextension-polyfill";

const AB_DM_POPUP_CLASSNAME = "ab_dm_popup_class";
let showingPopup = false;
let onClickListener = () => {};

export function setOnPopupClicked(listener: () => void) {
    onClickListener = listener;
}

export function showAddDownloadPopupUi(position: PositionInPage) {
    if (showingPopup) closeAddDownloadPopupUi();
    createUi(position, () => {
        try { onClickListener(); } finally { closeAddDownloadPopupUi(); }
    }, closeAddDownloadPopupUi);
    showingPopup = true;
}

export function closeAddDownloadPopupUi() {
    document.removeEventListener("mousedown", closeAddDownloadPopupUi);
    document.body.querySelectorAll(`.${AB_DM_POPUP_CLASSNAME}`).forEach(el => el.remove());
    showingPopup = false;
}

function createUi(position: PositionInPage, onAction: () => void, onCancel: () => void) {
    const el = document.createElement("div");
    const shadowRoot = el.attachShadow({mode: "open"});
    const downloadSelectedText = browser.i18n.getMessage("selection_popup_download_selected");
    const closeLabel = browser.i18n.getMessage("close");
    const styleEl = document.createElement("style");
    styleEl.textContent = `
      :host { all: initial; }
      .zjx-selection, .zjx-selection * { box-sizing: border-box; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
      .zjx-selection {
        display: flex; align-items: stretch; overflow: hidden; user-select: none;
        color: #1d1d1f; background: #fff; border: 1px solid #d6d6dc; border-radius: 10px;
        box-shadow: 0 4px 16px rgba(0,0,0,.18); font-size: 13px;
      }
      .zjx-selection button { display: inline-flex; align-items: center; gap: 8px; min-height: 36px; border: 0; cursor: pointer; font: inherit; }
      .zjx-selection .download-btn { padding: 0 12px 0 10px; color: #fff; background: #0878f9; font-weight: 600; }
      .zjx-selection .download-btn:hover { background: #0066d6; }
      .zjx-selection .close-btn { justify-content: center; width: 36px; padding: 0; color: #55555d; background: #f2f2f5; border-left: 1px solid #d6d6dc; font-size: 18px; }
      .zjx-selection .close-btn:hover { color: #1d1d1f; background: #e8e8ed; }
      .zjx-selection img { width: 18px; height: 18px; object-fit: contain; }
      .zjx-selection button:focus-visible { outline: 3px solid #70adff; outline-offset: -3px; }
      @media (prefers-color-scheme: dark) {
        .zjx-selection { color: #f5f5f7; background: #2b2b2e; border-color: #4a4a50; }
        .zjx-selection .download-btn { background: #267fe3; }
        .zjx-selection .download-btn:hover { background: #4b9bff; }
        .zjx-selection .close-btn { color: #c3c3ca; background: #242427; border-color: #4a4a50; }
        .zjx-selection .close-btn:hover { color: #fff; background: #38383c; }
      }
      @media (prefers-reduced-motion: reduce) { *, *::before, *::after { transition: none !important; animation: none !important; } }
    `;
    shadowRoot.appendChild(styleEl);

    const root = document.createElement("div");
    root.className = "zjx-selection";
    root.dir = "auto";
    const downloadButton = document.createElement("button");
    downloadButton.className = "download-btn";
    downloadButton.type = "button";
    const icon = document.createElement("img");
    icon.alt = "";
    icon.src = browser.runtime.getURL("icons/icon-32.png");
    const label = document.createElement("span");
    label.textContent = downloadSelectedText;
    downloadButton.append(icon, label);

    const closeButton = document.createElement("button");
    closeButton.className = "close-btn";
    closeButton.type = "button";
    closeButton.title = closeLabel;
    closeButton.setAttribute("aria-label", closeLabel);
    closeButton.textContent = "×";
    root.append(downloadButton, closeButton);
    shadowRoot.appendChild(root);
    el.classList.add(AB_DM_POPUP_CLASSNAME);
    el.style.position = "absolute";
    document.body.append(el);

    const elWidth = el.getBoundingClientRect().width;
    const offsetX = position.x + elWidth >= window.innerWidth
        ? Math.max(0, window.innerWidth - (elWidth + getScrollbarWidth()))
        : Math.max(0, position.x);
    el.style.zIndex = "9999";
    el.style.top = `${Math.max(0, position.y)}px`;
    el.style.left = `${offsetX}px`;

    for (const button of [downloadButton, closeButton]) {
        button.addEventListener("mousedown", event => event.stopPropagation());
    }
    downloadButton.addEventListener("click", event => { event.stopPropagation(); onAction(); });
    closeButton.addEventListener("click", event => { event.stopPropagation(); onCancel(); });
    return el;
}

function getScrollbarWidth() {
    return window.innerWidth - document.body.clientWidth;
}
