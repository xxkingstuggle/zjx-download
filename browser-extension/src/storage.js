export const DEFAULTS = {
  port: 15151,
  apiKey: "",
  apiRequiresKey: false,
  autoCapture: false,
  showPageWidgets: true,
  sendRequestHeaders: false,
  silentAdd: false,
  silentStart: false,
  closeCapturedTab: true,
  bypassKey: "Backspace",
  minimumSizeKB: 0,
  extensions: ["zip", "rar", "7z", "iso", "tar", "gz", "exe", "msi", "deb", "jar", "apk", "bin", "mp3", "aac", "pdf", "mp4", "3gp", "avi", "mkv", "wav", "mpeg", "srt"],
  ignoredPatterns: [],
  requestHeadersPermissionGranted: false,
  siteAccessGranted: false
};
export async function getConfig() {
  const local = await chrome.storage.local.get(DEFAULTS);
  return {...DEFAULTS, ...local, port: validPort(local.port) ? Number(local.port) : DEFAULTS.port};
}
export function validPort(value) { const number = Number(value); return Number.isInteger(number) && number >= 1024 && number <= 65535; }
export async function saveConfig(patch) {
  const current = await getConfig();
  const changed = Object.fromEntries(Object.entries(patch).filter(([key, value]) => JSON.stringify(current[key]) !== JSON.stringify(value)));
  if (Object.keys(changed).length) await chrome.storage.local.set(changed);
  return {...current, ...patch};
}
