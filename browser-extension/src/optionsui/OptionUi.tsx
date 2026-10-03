import React, {ReactNode, useEffect, useMemo, useState} from "react";
import "~/assets/css/styles.css"
import {EventAwareViewModel, useViewModel} from "~/base/BaseViewModel";
import {makeObservable, observable} from "mobx";
import {observer} from "mobx-react-lite"
import {run} from "~/utils/ScopeFunctions";
import * as Configs from "~/configs/Config";
import {Config, configKeys, getDefaultConfig} from "~/configs/Config";
import {constraintIn} from "~/utils/NumberUtils";
import {AppIcon, SettingsIcon} from "~/components/ReactIcons";
import {sendMessage} from "webext-bridge/options"
import {arrayEquals} from "~/utils/ArrayUtils";
import browser from "webextension-polyfill";
import Constants from "~/utils/Constants";
import classNames from "classnames";
import {isBlank} from "~/utils/StringUtils";
import AutoGrowingTextarea from "~/optionsui/AutoGrowingTextarea";
import {DefinedCommands} from "~/message/Commands";
import {Nullable, WithSetters} from "~/utils/Types";
import {defineExtensionEntry} from "~/utils/DefineExtensionEntry";
import {createRoot} from "react-dom/client";
import OptionUiEntryType from "~/utils/EntryPointTypes/OptionUi/OptionUiEntryType";
import {isModifierKey, normalizeShortcut, parseShortcut} from "~/utils/Shortcut";
import {isMac} from "~/utils/platform/Platform";

class ToolsViewModelEvent {
}

class PortTestResult extends ToolsViewModelEvent {
    constructor(
        public port: number,
        public isSuccess: boolean,
        public message: Nullable<string> = null
    ) {
        super();
    }
}

type ConfigsWithSomeSetters = Omit<WithSetters<Configs.Config>,
    | "setCloseNewTabIfItWasCaptured"
    | "setBypassShortcut"
>
type ConnectionTestState = {status: "checking" | "success" | "failure", port: number} | null

class ToolsViewModel extends EventAwareViewModel<ToolsViewModelEvent> implements ConfigsWithSomeSetters {

    constructor(initialStates: Configs.Config) {
        super();
        makeObservable(this)
        configKeys.forEach((k) => {
            this.setConfigItem(k, initialStates[k])
        })
    }

    readonly defaultConfig = getDefaultConfig();

    private setConfigItem<K extends keyof Config>(key: K, value: Config[K]) {
        (this as Config)[key] = value
    }

    protected setUp() {
        Configs.onChanged.addEventListener((config) => {
            configKeys.forEach((k) => {
                this.setConfigItem(k, config[k])
            })
        })
        this.testNativeMessaging()
    }

    @observable
    popupEnabled!: boolean
    @observable
    autoCaptureLinks!: boolean

    @observable
    silentAddDownload!: boolean
    @observable
    silentStartDownload!: boolean

    @observable
    port!: number

    @observable
    apiKey!: string

    @observable
    sendHeaders!: boolean

    @observable
    registeredFileTypes!: string[]

    @observable
    blacklistedUrls!: string[]

    @observable
    allowPassDownloadIfAppNotRespond!: boolean

    @observable
    closeNewTabIfItWasCaptured!: boolean

    @observable
    captureFileSizeMinimumKb!: number

    @observable
    bypassShortcut!: string

    setAutoCaptureLinks(value: boolean) {
        Configs.setConfigItem("autoCaptureLinks", value)
    }

    setRegisteredFileTypes(types: string[]) {
        Configs.setConfigItem("registeredFileTypes", [...new Set(types)])
    }

    setBlacklistedUrls(blacklistedUrls: string[]) {
        Configs.setConfigItem("blacklistedUrls", [...new Set(blacklistedUrls)])
    }

    setCaptureFileSizeMinimumKb(value: number) {
        Configs.setConfigItem("captureFileSizeMinimumKb", value)
    }

    setShortCut(value: string) {
        Configs.setConfigItem("bypassShortcut", value)
    }

    setPopupEnabled(value: boolean) {
        Configs.setConfigItem("popupEnabled", value)
    }

    setSilentAddDownload(value: boolean) {
        Configs.setConfigItem("silentAddDownload", value)
    }

    setSilentStartDownload(value: boolean) {
        Configs.setConfigItem("silentStartDownload", value)
    }

    setPort(value: number) {
        Configs.setConfigItem("port", value)
    }

    setApiKey(value: string) {
        Configs.setConfigItem("apiKey", value)
    }

    setSendHeaders(value: boolean) {
        Configs.setConfigItem("sendHeaders", value)
    }

    setAllowPassDownloadIfAppNotRespond(value: boolean) {
        Configs.setConfigItem("allowPassDownloadIfAppNotRespond", value)
    }

    setCloseNewTabIfItWasCaptured(value: boolean) {
        Configs.setConfigItem("closeNewTabIfItWasCaptured", value)
    }

    @observable
    nativeMessagingAvailable: boolean | null = null

    testNativeMessaging() {
        run(async () => {
            const result = await sendMessage(DefinedCommands.TEST_NATIVE_MESSAGING, undefined, "background")
            if (typeof result === "boolean") {
                this.nativeMessagingAvailable = result
            } else {
                console.log("there is no valid result for ping")
            }
        })
    }

    testHttpPort(port = this.port, apiKey = this.apiKey) {
        run(async () => {
            try {
                const result = await sendMessage(DefinedCommands.TEST_HTTP_PORT, { port, apiKey }, "background")
                this.onEvent(new PortTestResult(port, result === true))
            } catch {
                this.onEvent(new PortTestResult(port, false))
            }
        })
    }

}


const App: React.FC<{
    vm: ToolsViewModel
}> = observer((props) => {
    const vm = useViewModel(() => props.vm)
    const [connectionTest, setConnectionTest] = useState<ConnectionTestState>(null)
    useEffect(() => {
        const listener = (event: ToolsViewModelEvent) => {
            if (event instanceof PortTestResult) {
                setConnectionTest({status: event.isSuccess ? "success" : "failure", port: event.port})
            }
        }
        vm.addEventListener(listener)
        return () => vm.removeEventListener(listener)
    }, [vm]);
    return <main className="app-shell settings-shell">
        <Header/>
        <SettingsSection
            vm={vm}
            connectionTest={connectionTest}
            requestConnectionTest={(port, apiKey) => {
                setConnectionTest({status: "checking", port})
                vm.testHttpPort(port, apiKey)
            }}
        />
        <Footer/>
    </main>
})

function Header() {
    return <header className="settings-brand">
        <AppIcon className="h-12 w-12"/>
        <div>
            <div className="settings-brand-title">zjx-download</div>
            <div className="settings-brand-subtitle">{browser.i18n.getMessage("option_ui_title")}</div>
        </div>
    </header>
}

function Footer() {
    return <footer className="footer-links">
        <span className="helper-text">
            {browser.i18n.getMessage("note_about_app_must_be_installed_first")}
            {" "}<a target="_blank"
                    rel="noreferrer"
                    href={Constants.downloadAppUrl}>
            {<span>{browser.i18n.getMessage("download_abdm_app")
            }</span>}
            </a>
        </span>
        <div>
            <a target="_blank" rel="noreferrer"
               href={Constants.feedback}>{browser.i18n.getMessage("support_by_rating")}</a>
        </div>
        <div className="flex flex-row flex-wrap gap-x-4 gap-y-2">
            <a target="_blank" rel="noreferrer"
               href={Constants.website}>{browser.i18n.getMessage("project_website")}</a>
            <a target="_blank" rel="noreferrer"
               href={Constants.repository}>{browser.i18n.getMessage("project_source_code")}</a>
        </div>
    </footer>
}

const SettingsSection: React.FC<{
    vm: ToolsViewModel,
    connectionTest: ConnectionTestState,
    requestConnectionTest: (port: number, apiKey: string) => void,
}> = observer((props) => {
    const vm = props.vm
    return <section aria-label={browser.i18n.getMessage("settings")} className="settings-groups">
        <SettingsGroup titleKey="settings_group_connection" descriptionKey="settings_group_connection_description">
            <NativeMessagingSection isNativeMessagingAvailable={vm.nativeMessagingAvailable}/>
            <HttpApiSection
                port={vm.port}
                setPort={(p) => vm.setPort(p)}
                apiKey={vm.apiKey}
                setApiKey={(p) => vm.setApiKey(p)}
                onRequestTestPort={props.requestConnectionTest}
                connectionTest={props.connectionTest}
            />
        </SettingsGroup>
        <SettingsGroup titleKey="settings_group_download_handoff" descriptionKey="settings_group_download_handoff_description">
            <AutoCaptureToggle value={vm.autoCaptureLinks} toggle={v => vm.setAutoCaptureLinks(v)}/>
            <ShowPopupSection value={vm.popupEnabled} toggle={(v) => vm.setPopupEnabled(v)}/>
            <SilentDownloadSection
                silentAddEnabled={vm.silentAddDownload}
                setSilentAddEnabled={(v) => vm.setSilentAddDownload(v)}
                silentStartEnabled={vm.silentStartDownload}
                setSilentStartEnabled={(v) => vm.setSilentStartDownload(v)}
            />
            <AllowPassDownloadIfAppNotRespondSection
                enabled={vm.allowPassDownloadIfAppNotRespond}
                toggle={(v) => vm.setAllowPassDownloadIfAppNotRespond(v)}
            />
            <CloseNewTabSection
                enabled={vm.closeNewTabIfItWasCaptured}
                toggle={v => vm.setCloseNewTabIfItWasCaptured(v)}
            />
        </SettingsGroup>
        <SettingsGroup titleKey="settings_group_website_rules" descriptionKey="settings_group_website_rules_description">
            <WebsiteRulesSection
                fileTypes={vm.registeredFileTypes}
                defaultFileTypes={vm.defaultConfig.registeredFileTypes}
                blacklistedUrls={vm.blacklistedUrls}
                defaultBlacklistedUrls={vm.defaultConfig.blacklistedUrls}
                setFileTypes={types => vm.setRegisteredFileTypes(types)}
                setBlacklistedUrls={urls => vm.setBlacklistedUrls(urls)}
                captureFileSizeMinimumKb={vm.captureFileSizeMinimumKb}
                setCaptureFileSizeMinimumKb={(v) => vm.setCaptureFileSizeMinimumKb(v)}
                bypassShortcut={vm.bypassShortcut}
                defaultBypassShortcut={vm.defaultConfig.bypassShortcut}
                setBypassShortcut={(v) => vm.setShortCut(v)}
            />
        </SettingsGroup>
        <SettingsGroup titleKey="settings_group_advanced" descriptionKey="settings_group_advanced_description">
            <SendCookiesSection enabled={vm.sendHeaders} toggle={(v) => vm.setSendHeaders(v)}/>
        </SettingsGroup>
    </section>
})

function SettingsGroup(props: {titleKey: string, descriptionKey: string, children: ReactNode}) {
    return <section className="settings-group">
        <h2 className="settings-group-title">{browser.i18n.getMessage(props.titleKey)}</h2>
        <div className="settings-group-description">{browser.i18n.getMessage(props.descriptionKey)}</div>
        {props.children}
    </section>
}

function OptionItem(
    props: {
        title: ReactNode,
        toggle: ReactNode,
        description: ReactNode,
        enabled?: boolean,
        className?: string,
    }
) {
    const enabled = props.enabled ?? true
    return <div className={classNames("setting-row", props.className, !enabled && "cursor-not-allowed opacity-60")}>
        <div className="setting-toggle-head">
            <div className="setting-title">{props.title}</div>
            <div className="setting-control">{props.toggle}</div>
        </div>
        <div className="setting-description">{props.description}</div>
    </div>
}

function ShowPopupSection(
    props: {
        value: boolean,
        toggle: (v: boolean) => void
    }
) {
    return <OptionItem
        title={
            <div>{browser.i18n.getMessage("config_show_popups")}</div>
        }
        toggle={
            <input checked={props.value} onChange={event => props.toggle(event.target.checked)} type="checkbox"
                   className="checkbox" aria-label={browser.i18n.getMessage("config_show_popups")}/>
        }
        description={
            <div>{browser.i18n.getMessage("config_show_popups_description")}</div>
        }
    />
}

function SilentDownloadSection(
    props: {
        silentAddEnabled: boolean,
        silentStartEnabled: boolean,
        setSilentAddEnabled: (v: boolean) => void,
        setSilentStartEnabled: (v: boolean) => void,
    }
) {
    return <div>
        <OptionItem
            title={
                <div>{browser.i18n.getMessage("config_silent_add_download")}</div>
            }
            toggle={
                <input checked={props.silentAddEnabled}
                       onChange={event => props.setSilentAddEnabled(event.target.checked)} type="checkbox"
                       className="checkbox" aria-label={browser.i18n.getMessage("config_silent_add_download")}/>
            }
            description={
                <div>{browser.i18n.getMessage("config_silent_add_download_description")}</div>
            }
        />
        <OptionItem
            className="px-4 pt-4"
            enabled={props.silentAddEnabled}
            title={
                <div>{browser.i18n.getMessage("config_silent_start_download")}</div>
            }
            toggle={
                <input
                    checked={props.silentStartEnabled}
                    onChange={event => {
                        if (!props.silentAddEnabled) {
                            return
                        }
                        props.setSilentStartEnabled(event.target.checked)
                    }}
                    type="checkbox"
                    disabled={!props.silentAddEnabled}
                    aria-label={browser.i18n.getMessage("config_silent_start_download")}
                    className={classNames(
                        "checkbox",
                        !props.silentAddEnabled && "input-disabled"
                    )}
                />
            }
            description={
                <div>{browser.i18n.getMessage("config_silent_start_download_description")}</div>
            }
        />
    </div>
}

function AutoCaptureToggle(props: {value: boolean, toggle: (v: boolean) => void}) {
    return <OptionItem
        title={browser.i18n.getMessage("config_auto_capture_links")}
        toggle={<input checked={props.value} onChange={event => props.toggle(event.target.checked)} type="checkbox" className="checkbox" aria-label={browser.i18n.getMessage("config_auto_capture_links")}/>}
        description={browser.i18n.getMessage("config_auto_capture_links_description")}
    />
}

function WebsiteRulesSection(props: {
    fileTypes: string[]
    setFileTypes: (fileTypes: string[]) => void,
    defaultFileTypes: string[],
    blacklistedUrls: string[]
    setBlacklistedUrls: (urls: string[]) => void,
    defaultBlacklistedUrls: string[],
    captureFileSizeMinimumKb: number,
    setCaptureFileSizeMinimumKb: (n: number) => void,
    bypassShortcut: string,
    defaultBypassShortcut: string,
    setBypassShortcut: (s: string) => void,
}) {
    const [fileTypesString, setFileTypesString] = useState<string>(() => {
        return props.fileTypes.join(" ")
    })
    const canBeResetTypes = useMemo(() => {
        return !arrayEquals(props.defaultFileTypes, props.fileTypes)
    }, [props.fileTypes])
    useEffect(() => {
        props.setFileTypes(
            fileTypesString
                .split(" ")
                .filter(l => !isBlank(l))
        )
    }, [fileTypesString]);
    useEffect(() => {
        setFileTypesString(props.fileTypes.join(" "))
    }, [canBeResetTypes]);

    const [urlsString, setUrlsString] = useState<string>(() => props.blacklistedUrls.join("\n"))
    const canBeResetBlacklistedUrls = useMemo(() => {
        return !arrayEquals(props.defaultBlacklistedUrls, props.blacklistedUrls)
    }, [props.blacklistedUrls])
    useEffect(() => {
        props.setBlacklistedUrls(
            urlsString
                .split("\n")
                .filter(l => !isBlank(l))
        )
    }, [urlsString]);
    useEffect(() => {
        setUrlsString(props.blacklistedUrls.join("\n"))
    }, [canBeResetBlacklistedUrls]);

    return <div className="setting-row setting-stack">
        <div>
            <label htmlFor="file-types" className="field-label">{browser.i18n.getMessage("config_file_extensions")}</label>
            <AutoGrowingTextarea
                id="file-types"
                aria-label={browser.i18n.getMessage("config_file_extensions")}
                className="textarea"
                value={fileTypesString}
                onChange={event => setFileTypesString(event.target.value.toLowerCase())}
                rows={2}
            />
            {canBeResetTypes && <button type="button" onClick={() => props.setFileTypes(props.defaultFileTypes)} className="inline-button">
                {browser.i18n.getMessage("reset_to_default")}
            </button>}
            <div className="helper-text">{browser.i18n.getMessage("config_auto_capture_links_file_extensions_description")}</div>
        </div>
        <div>
            <label htmlFor="ignored-urls" className="field-label">{browser.i18n.getMessage("config_ignored_url_patterns")}</label>
            <AutoGrowingTextarea
                id="ignored-urls"
                aria-label={browser.i18n.getMessage("config_ignored_url_patterns")}
                className="textarea"
                value={urlsString}
                onChange={event => setUrlsString(event.target.value)}
                rows={3}
            />
            {canBeResetBlacklistedUrls && <button type="button" onClick={() => props.setBlacklistedUrls(props.defaultBlacklistedUrls)} className="inline-button">
                {browser.i18n.getMessage("reset_to_default")}
            </button>}
            <div className="helper-text">{browser.i18n.getMessage("config_blacklisted_urls_description")}</div>
        </div>
        <div className="setting-subsection setting-stack">
            <label className="field-label" htmlFor="capture-size-select">{browser.i18n.getMessage("config_capture_file_size_limit_kb")}</label>
            <select
                id="capture-size-select"
                value={[0, 102400, 512000, 1048576].includes(props.captureFileSizeMinimumKb) ? props.captureFileSizeMinimumKb : 0}
                onChange={event => props.setCaptureFileSizeMinimumKb(Number(event.target.value))}
            >
                <option value={0}>{browser.i18n.getMessage("config_no_limit_or_custom")}</option>
                <option value={102400}>100 MB</option>
                <option value={512000}>500 MB</option>
                <option value={1048576}>1 GB</option>
            </select>
            <div className="helper-text">{browser.i18n.getMessage("config_capture_file_size_limit_kb_description")}</div>
            <label className="field-label" htmlFor="capture-size-custom">{browser.i18n.getMessage("config_custom_value")}</label>
            <div className="port-controls">
                <input id="capture-size-custom" type="number" min={0} placeholder={browser.i18n.getMessage("config_enter_kb")} value={props.captureFileSizeMinimumKb} onChange={event => props.setCaptureFileSizeMinimumKb(Number(event.target.value || 0))}/>
                <span className="helper-text">KB</span>
            </div>
        </div>
        <div className="setting-subsection setting-stack">
            <label className="field-label">{browser.i18n.getMessage("config_bypass_shortcut")}</label>
            <ShortcutCapture value={props.bypassShortcut} defaultValue={props.defaultBypassShortcut} onChange={props.setBypassShortcut}/>
            <div className="helper-text">{browser.i18n.getMessage("config_bypass_shortcut_description")}</div>
        </div>
    </div>
}

function ShortcutCapture(
    props: {
        value: string,
        defaultValue?: string,
        onChange: (shortcut: string) => void,
        className?: string,
    }
) {
    const [isCapturing, setIsCapturing] = useState(false)
    const [heldModifiers, setHeldModifiers] = useState<string[]>([])
    const canBeReset = useMemo(() => {
        return props.defaultValue !== undefined && props.defaultValue !== props.value
    }, [props.defaultValue, props.value])
    // ctrl+click is the secondary click on mac, the click never reaches the page
    const isUnusableOnMac = useMemo(() => {
        return isMac() && parseShortcut(props.value).includes("Control")
    }, [props.value])

    function stopCapturing(target: EventTarget | null) {
        setHeldModifiers([])
        setIsCapturing(false)
        ;(target as HTMLElement | null)?.blur()
    }

    function modifiersOf(e: React.KeyboardEvent): string[] {
        const modifiers: string[] = []
        if (e.ctrlKey) modifiers.push("Control")
        if (e.altKey) modifiers.push("Alt")
        if (e.shiftKey) modifiers.push("Shift")
        if (e.metaKey) modifiers.push("Meta")
        return modifiers
    }

    return <div className="flex flex-col space-y-2">
        <div className="flex items-center space-x-2">
            <input
                type="text"
                readOnly
                aria-label={browser.i18n.getMessage("config_bypass_shortcut")}
                value={isCapturing ? normalizeShortcut(heldModifiers) : props.value}
                placeholder={
                    isCapturing
                        ? browser.i18n.getMessage("config_press_a_key")
                        : props.value
                }
                onFocus={() => setIsCapturing(true)}
                onBlur={() => {
                    setHeldModifiers([])
                    setIsCapturing(false)
                }}
                onKeyDown={(e) => {
                    // tab is left alone, it is the only way out of the field with the keyboard
                    if (e.key === "Tab") {
                        stopCapturing(null)
                        return
                    }
                    e.preventDefault()
                    e.stopPropagation()
                    // escape cancels and keeps the previous shortcut
                    if (e.key === "Escape") {
                        stopCapturing(e.target)
                        return
                    }
                    const modifiers = modifiersOf(e)
                    if (isModifierKey(e.key)) {
                        setHeldModifiers(modifiers)
                        return
                    }
                    props.onChange(normalizeShortcut([...modifiers, e.key]))
                    stopCapturing(e.target)
                }}
                onKeyUp={(e) => {
                    // a shortcut made only of modifiers is taken when the first one is released
                    if (!isCapturing || heldModifiers.length === 0) {
                        return
                    }
                    e.preventDefault()
                    props.onChange(normalizeShortcut(heldModifiers))
                    stopCapturing(e.target)
                }}
                className={classNames(
                    "input input-sm flex-1 cursor-pointer select-none",
                    isCapturing && "input-primary ring-2 ring-primary",
                    props.className
                )}
            />
        </div>
        {
            isUnusableOnMac && (
                <div className="text-warning">
                    {browser.i18n.getMessage("config_bypass_shortcut_control_mac_warning")}
                </div>
            )
        }
        {
            canBeReset && (
                <button type="button"
                    onClick={() => props.defaultValue !== undefined && props.onChange(props.defaultValue)}
                    className="inline-button">
                    {browser.i18n.getMessage("reset_to_default")}
                </button>
            )
        }
    </div>
}

function HttpApiSection(
    props: {
        port: number,
        setPort: (number: number) => void,
        apiKey: string,
        setApiKey: (key: string) => void,
        onRequestTestPort: (port: number, apiKey: string) => void,
        connectionTest: ConnectionTestState,
    }
) {
    const [value, setValue] = useState(props.port)
    const [isApiKeyVisible, setApiKeyVisible] = useState(false)
    useEffect(() => {
        setValue(props.port)
    }, [props.port])

    function emitData() {
        const newPort = constraintIn(value, Configs.MIN_ALLOWED_PORT, Configs.MAX_ALLOWED_PORT)
        setValue(newPort)
        props.setPort(newPort)
    }

    const testMessage = props.connectionTest
        ? browser.i18n.getMessage(
            props.connectionTest.status === "checking" ? "connection_test_checking" :
                props.connectionTest.status === "success" ? "connection_test_success" : "connection_test_failure",
            [`${props.connectionTest.port}`],
        )
        : ""

    return <div>
        <div className="setting-row">
            <label htmlFor="app-port" className="field-label">{browser.i18n.getMessage("config_port")}</label>
            <div className="port-controls">
                <input
                    id="app-port"
                    aria-describedby="app-port-description"
                    value={value}
                    onBlur={emitData}
                    onChange={event => {
                        const nextValue = event.target.value
                        if (nextValue === "") return
                        const nextPort = Number.parseInt(nextValue)
                        if (!Number.isNaN(nextPort)) setValue(nextPort)
                    }}
                    type="number"
                    min={Configs.MIN_ALLOWED_PORT}
                    max={Configs.MAX_ALLOWED_PORT}
                />
                <button
                    type="button"
                    disabled={props.connectionTest?.status === "checking"}
                    onClick={() => {
                        const testPort = constraintIn(value, Configs.MIN_ALLOWED_PORT, Configs.MAX_ALLOWED_PORT)
                        setValue(testPort)
                        props.setPort(testPort)
                        props.onRequestTestPort(testPort, props.apiKey)
                    }}
                    className="zjx-button"
                >
                    {props.connectionTest?.status === "checking" ? browser.i18n.getMessage("connection_test_running") : browser.i18n.getMessage("test")}
                </button>
            </div>
            <div id="app-port-description" className="setting-description">{browser.i18n.getMessage("config_port_description")}</div>
            <div
                role="status"
                aria-live="polite"
                className={classNames("connection-result", props.connectionTest?.status === "success" && "is-success", props.connectionTest?.status === "failure" && "is-error")}
            >{testMessage}</div>
        </div>
        <div className="setting-row">
            <label htmlFor="app-api-key" className="field-label">{browser.i18n.getMessage("config_api_key")}</label>
            <div className="port-controls api-key-controls">
                <input
                    id="app-api-key"
                    aria-describedby="app-api-key-description"
                    value={props.apiKey}
                    onChange={event => props.setApiKey(event.target.value)}
                    type={isApiKeyVisible ? "text" : "password"}
                    autoComplete="off"
                    spellCheck={false}
                />
                <button type="button" className="zjx-button zjx-button-secondary" onClick={() => setApiKeyVisible(!isApiKeyVisible)}>
                    {browser.i18n.getMessage(isApiKeyVisible ? "api_key_hide" : "api_key_show")}
                </button>
            </div>
            <div id="app-api-key-description" className="setting-description">{browser.i18n.getMessage("config_api_key_description")}</div>
        </div>
    </div>
}

function NativeMessagingSection(
    props: {
        isNativeMessagingAvailable: boolean | null
    }
) {
    let reachableContent
    if (props.isNativeMessagingAvailable === true) {
        reachableContent = <div className="helper-text" role="status">
            {browser.i18n.getMessage("config_native_messaging_host_reachable")}
        </div>
    }
    if (props.isNativeMessagingAvailable === false) {
        reachableContent = <div className="helper-text" role="status">
            {browser.i18n.getMessage("config_native_messaging_host_not_reachable")}
        </div>
    }
    if (props.isNativeMessagingAvailable === null) {
        reachableContent = <div className="helper-text" role="status" aria-live="polite">
            {browser.i18n.getMessage("config_native_messaging_checking")}
        </div>
    }

    return <div>
        <OptionItem
            title={
                <div>{browser.i18n.getMessage("config_native_messaging_host")}</div>
            }
            toggle={reachableContent}
            description={
                <div>
                    {browser.i18n.getMessage("config_native_messaging_host_description")}
                </div>
            }
        />
    </div>
}

function SendCookiesSection(
    props: {
        enabled: boolean,
        toggle: (v: boolean) => void
    }
) {
    return <OptionItem
        title={
            <div>{browser.i18n.getMessage("config_send_cookies")}</div>
        }
        toggle={
            <input checked={props.enabled} onChange={e => props.toggle(e.target.checked)} type="checkbox"
                   className="checkbox" aria-label={browser.i18n.getMessage("config_send_cookies")}/>
        }
        description={
            <div>
                {browser.i18n.getMessage("config_send_cookies_descrption")}
            </div>
        }
    />
}

function AllowPassDownloadIfAppNotRespondSection(
    props: {
        enabled: boolean,
        toggle: (v: boolean) => void
    }
) {
    const title = browser.i18n.getMessage("config_fallback_to_browser")
        || "Continue the browser download if zjx-download is unavailable"
    const description = browser.i18n.getMessage("config_fallback_to_browser_description")
        || "When the app cannot accept a captured download, keep Chrome's original download running."
    return <OptionItem
        title={<div>{title}</div>}
        toggle={
            <input checked={props.enabled} onChange={e => props.toggle(e.target.checked)} type="checkbox"
                   className="checkbox" aria-label={title}/>
        }
        description={<div>{description}</div>}
    />
}

function CloseNewTabSection(props: {enabled: boolean, toggle: (value: boolean) => void}) {
    return <OptionItem
        title={browser.i18n.getMessage("config_close_captured_tab")}
        toggle={<input checked={props.enabled} onChange={event => props.toggle(event.target.checked)} type="checkbox" className="checkbox" aria-label={browser.i18n.getMessage("config_close_captured_tab")}/>}
        description={browser.i18n.getMessage("config_close_captured_tab_description")}
    />
}

export default defineExtensionEntry()
    .withType(OptionUiEntryType)
    .withInit(async (ctx) => {
        document.documentElement.lang = browser.i18n.getUILanguage()
        const vm = new ToolsViewModel(ctx.getLatestConfig())
        const container = document.getElementById("app")!
        createRoot(container).render(
            <App vm={vm}/>
        )
    })
