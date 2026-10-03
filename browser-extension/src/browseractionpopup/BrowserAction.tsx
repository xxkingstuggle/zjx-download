import React from "react";
import "~/assets/css/styles.css"
import {BaseViewModel, useViewModel} from "~/base/BaseViewModel";
import {action, makeObservable, observable} from "mobx";
import {observer} from "mobx-react-lite"
import {run} from "~/utils/ScopeFunctions";
import * as Configs from "~/configs/Config";
import browser from "webextension-polyfill";
import {AppIcon, SettingsIcon} from "~/components/ReactIcons";
import {sendMessage} from "webext-bridge/popup";
import {DefinedCommands} from "~/message/Commands";
import {defineExtensionEntry} from "~/utils/DefineExtensionEntry";
import {createRoot} from "react-dom/client";
import BrowserActionEntryType from "~/utils/EntryPointTypes/BrowserAction/BrowserActionEntryType";

class BrowserActionViewModel extends BaseViewModel {
    constructor(initialStates: Configs.Config) {
        super();
        makeObservable(this)
        Object.keys(initialStates).forEach((key) => {
            // @ts-ignore
            this[key] = initialStates[key]
        })
    }

    protected setUp() {
        Configs.onChanged.addEventListener((config) => {
            this.autoCaptureLinks = config.autoCaptureLinks
            this.popupEnabled = config.popupEnabled
            this.silentAddDownload = config.silentAddDownload
        })
        run(async () => {
            try {
                const isAppReachable = await sendMessage(
                    DefinedCommands.IS_APP_REACHABLE,
                    undefined,
                    "background",
                )
                this.setCanReachable(isAppReachable)
            } catch {
                this.setCanReachable(false)
            }
        })
    }

    @observable popupEnabled!: boolean
    @observable autoCaptureLinks!: boolean
    @observable silentAddDownload!: boolean
    @observable canReachable: boolean | null = null

    @action setCanReachable(value: boolean) {
        this.canReachable = value
    }

    setAutoCaptureLinks(value: boolean) { Configs.setConfigItem("autoCaptureLinks", value) }
    setPopupEnabled(value: boolean) { Configs.setConfigItem("popupEnabled", value) }
    setSilentAddDownload(value: boolean) { Configs.setConfigItem("silentAddDownload", value) }
}

function ConnectionStatus({reachable}: {reachable: boolean | null}) {
    const statusKey = reachable === true
        ? "connection_connected"
        : reachable === false ? "connection_not_connected" : "connection_checking"
    const statusClass = reachable === true ? "is-online" : reachable === false ? "is-offline" : ""
    return <div className="connection-status" role="status" aria-live="polite">
        <span className={`status-dot ${statusClass}`} aria-hidden="true"/>
        <span>{browser.i18n.getMessage(statusKey)}{reachable === null ? "…" : ""}</span>
    </div>
}

const BrowserActionUi: React.FC<{vm: BrowserActionViewModel}> = observer(({vm: inputVm}) => {
    const vm = useViewModel(() => inputVm)
    return <main className="app-shell popup-shell">
        <section className="popup-card" aria-label={browser.i18n.getMessage("browser_action_popup_title")}>
            <header className="popup-header">
                <AppIcon className="h-9 w-9"/>
                <div className="popup-brand">
                    <div className="popup-brand-name">zjx-download</div>
                    <ConnectionStatus reachable={vm.canReachable}/>
                </div>
            </header>
            {vm.canReachable === false && <div className="status-help">
                {browser.i18n.getMessage("connection_status_help")}
            </div>}
            <div>
                <PreferenceRow
                    title={browser.i18n.getMessage("config_auto_capture_links")}
                    description={browser.i18n.getMessage("config_auto_capture_links_description")}
                    enabled={vm.autoCaptureLinks}
                    toggle={vm.setAutoCaptureLinks.bind(vm)}
                />
                <PreferenceRow
                    title={browser.i18n.getMessage("config_show_popups")}
                    description={browser.i18n.getMessage("config_show_popups_description")}
                    enabled={vm.popupEnabled}
                    toggle={vm.setPopupEnabled.bind(vm)}
                />
                <PreferenceRow
                    title={browser.i18n.getMessage("config_silent_add_download")}
                    description={browser.i18n.getMessage("config_silent_add_download_description_short")}
                    enabled={vm.silentAddDownload}
                    toggle={vm.setSilentAddDownload.bind(vm)}
                />
            </div>
            <button className="popup-footer" type="button" onClick={() => browser.runtime.openOptionsPage()}>
                <span className="popup-footer-label">{browser.i18n.getMessage("browser_action_more_settings")}</span>
                <SettingsIcon className="popup-footer-icon"/>
            </button>
        </section>
    </main>
})

function PreferenceRow(props: {
    title: string,
    description: string,
    enabled: boolean,
    toggle: (value: boolean) => void,
}) {
    return <label className="popup-row">
        <span>
            <span className="popup-row-title block">{props.title}</span>
            <span className="popup-row-description block">{props.description}</span>
        </span>
        <input
            type="checkbox"
            checked={props.enabled}
            onChange={event => props.toggle(event.currentTarget.checked)}
            aria-label={props.title}
        />
    </label>
}

export default defineExtensionEntry()
    .withType(BrowserActionEntryType)
    .withInit(async (context) => {
        document.documentElement.lang = browser.i18n.getUILanguage()
        const vm = new BrowserActionViewModel(context.getLatestConfig())
        const container = document.getElementById("app")!
        createRoot(container).render(<BrowserActionUi vm={vm}/>);
    })
