import {DownloadableMedia} from "~/media/MediaOnTab"
import browser from "webextension-polyfill"

let popupEl: HTMLDivElement | null = null
let dismissed = false
let listVisible = false
let onItemClick: ((item: DownloadableMedia) => void) | undefined

function createPopup() {
    if (popupEl) return popupEl
    const titleText = browser.i18n.getMessage("download_media_title")
    const closeText = browser.i18n.getMessage("close")
    const wrapper = document.createElement("div")
    wrapper.className = "abdm-extension"
    Object.assign(wrapper.style, {
        position: "fixed", top: "8px", left: "8px", zIndex: "999999",
        display: "flex", flexDirection: "column", alignItems: "flex-start", gap: "4px",
        direction: "ltr",
    })

    const styleEl = document.createElement("style")
    styleEl.textContent = `
      .abdm-extension, .abdm-extension * { box-sizing: border-box; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif !important; }
      .abdm-extension { width: min(320px, calc(100vw - 16px)); }
      .abdm-media-header, .abdm-media-list {
        color: #1d1d1f; background: #fff; border: 1px solid #d6d6dc; border-radius: 10px;
        box-shadow: 0 4px 16px rgba(0,0,0,.18); font-size: 13px;
      }
      .abdm-media-header { display: flex; align-items: center; gap: 8px; min-height: 38px; padding: 4px 8px; }
      .abdm-media-toggle { display: flex; align-items: center; gap: 8px; min-width: 0; flex: 1; border: 0; padding: 4px; text-align: left; color: inherit; background: transparent; font: inherit; cursor: pointer; }
      .abdm-media-toggle:hover { color: #0066d6; }
      .abdm-media-header .appIcon { width: 20px; height: 20px; flex: 0 0 auto; }
      .abdm-media-header .appIcon img { display: block; width: 100%; height: 100%; object-fit: contain; }
      .abdm-media-title { min-width: 0; }
      .abdm-media-count { color: #64646b; font-variant-numeric: tabular-nums; }
      .abdm-media-close-btn { display: inline-grid; place-items: center; width: 28px; height: 28px; padding: 0; border: 0; border-radius: 6px; color: #64646b; background: transparent; font: inherit; font-size: 18px; cursor: pointer; }
      .abdm-media-close-btn:hover { color: #1d1d1f; background: #f0f0f3; }
      .abdm-media-list { display: none; width: min(320px, calc(100vw - 16px)); max-height: min(50vh, 420px); overflow: auto; }
      .abdm-media-item { display: flex; flex-direction: column; align-items: flex-start; width: 100%; min-width: 0; padding: 9px 12px; border: 0; border-bottom: 1px solid #dedee3; color: inherit; background: transparent; text-align: left; cursor: pointer; }
      .abdm-media-item:last-child { border-bottom: 0; }
      .abdm-media-item:hover, .abdm-media-item:focus-visible { background: #f3f7ff; }
      .abdm-item-title { max-width: 100%; overflow-wrap: anywhere; font-weight: 600; }
      .abdm-item-details { margin-top: 2px; color: #64646b; font-size: 12px; }
      .abdm-extension button:focus-visible { outline: 3px solid #70adff; outline-offset: 1px; }
      @media (prefers-color-scheme: dark) {
        .abdm-media-header, .abdm-media-list { color: #f5f5f7; background: #2b2b2e; border-color: #4a4a50; }
        .abdm-media-toggle:hover { color: #75b1ff; }
        .abdm-media-count, .abdm-item-details, .abdm-media-close-btn { color: #c3c3ca; }
        .abdm-media-close-btn:hover { color: #fff; background: #38383c; }
        .abdm-media-item { border-color: #444449; }
        .abdm-media-item:hover, .abdm-media-item:focus-visible { background: #36363b; }
      }
      @media (prefers-reduced-motion: reduce) { *, *::before, *::after { transition: none !important; animation: none !important; } }
    `
    wrapper.appendChild(styleEl)

    const header = document.createElement("div")
    header.className = "abdm-media-header"
    header.setAttribute("role", "group")
    header.setAttribute("aria-label", "zjx-download")
    const toggle = document.createElement("button")
    toggle.type = "button"
    toggle.className = "abdm-media-toggle"
    toggle.setAttribute("aria-expanded", "false")
    const iconWrapper = document.createElement("span")
    iconWrapper.className = "appIcon"
    const icon = document.createElement("img")
    icon.alt = ""
    icon.src = browser.runtime.getURL("icons/icon-32.png")
    iconWrapper.appendChild(icon)
    const title = document.createElement("span")
    title.className = "abdm-media-title"
    title.textContent = titleText
    const count = document.createElement("span")
    count.className = "abdm-media-count"
    count.textContent = "0"
    toggle.append(iconWrapper, title, count)

    const closeButton = document.createElement("button")
    closeButton.type = "button"
    closeButton.className = "abdm-media-close-btn"
    closeButton.title = closeText
    closeButton.setAttribute("aria-label", closeText)
    closeButton.textContent = "×"
    header.append(toggle, closeButton)

    const list = document.createElement("div")
    list.className = "abdm-media-list"
    list.setAttribute("role", "region")
    list.setAttribute("aria-label", titleText)
    wrapper.append(header, list)
    toggle.addEventListener("click", event => {
        event.stopPropagation()
        listVisible = !listVisible
        list.style.display = listVisible ? "block" : "none"
        toggle.setAttribute("aria-expanded", String(listVisible))
    })
    closeButton.addEventListener("click", event => {
        event.stopPropagation()
        dismissed = true
        wrapper.remove()
        popupEl = null
    })
    document.body.appendChild(wrapper)
    popupEl = wrapper
    return wrapper
}

function getBiggestMediaPlayer() {
    return Array.from(document.querySelectorAll<HTMLMediaElement>("video, audio"))
        .sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0] || null
}

export function setItemClickListener(callback: (item: DownloadableMedia) => void) {
    onItemClick = callback
}

export function updatePopup(items: DownloadableMedia[]) {
    if (dismissed) return
    if (!items || items.length === 0) {
        popupEl?.remove()
        popupEl = null
        return
    }

    const popup = createPopup()
    const countEl = popup.querySelector<HTMLSpanElement>(".abdm-media-count")!
    countEl.textContent = String(items.length)
    const listContainer = popup.querySelector<HTMLDivElement>(".abdm-media-list")!
    listContainer.replaceChildren()

    for (const item of items) {
        const button = document.createElement("button")
        button.type = "button"
        button.className = "abdm-media-item"
        const title = document.createElement("span")
        title.className = "abdm-item-title"
        title.textContent = item.displayName || browser.i18n.getMessage("media_unnamed")
        const details = document.createElement("span")
        details.className = "abdm-item-details"
        details.textContent = [item.duration, item.size, item.resolution, item.bandwidth, item.extension].filter(Boolean).join(" · ")
        button.append(title, details)
        button.addEventListener("click", event => {
            event.stopPropagation()
            onItemClick?.(item)
        })
        listContainer.appendChild(button)
    }

    const media = getBiggestMediaPlayer()
    if (media) {
        const rect = media.getBoundingClientRect()
        popup.style.position = "absolute"
        popup.style.top = `${Math.max(rect.top - popup.offsetHeight - 2 + window.scrollY, 2)}px`
        popup.style.left = `${Math.max(2, Math.min(rect.left + window.scrollX, window.innerWidth - popup.offsetWidth - 2))}px`
    } else {
        popup.style.position = "fixed"
        popup.style.top = "8px"
        popup.style.left = "8px"
    }
}

export function toggleList(visible?: boolean) {
    if (!popupEl) return
    const list = popupEl.querySelector<HTMLDivElement>(".abdm-media-list")
    const toggle = popupEl.querySelector<HTMLButtonElement>(".abdm-media-toggle")
    if (!list || !toggle) return
    listVisible = visible ?? !listVisible
    list.style.display = listVisible ? "block" : "none"
    toggle.setAttribute("aria-expanded", String(listVisible))
}
