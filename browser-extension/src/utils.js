export function isHttpUrl(value) {
  if (typeof value !== "string" || !value.trim()) return false;
  try {
    const url = new URL(value.trim());
    return (url.protocol === "http:" || url.protocol === "https:") && Boolean(url.hostname);
  } catch {
    return false;
  }
}

export function wildcardMatch(pattern, value) {
  if (typeof pattern !== "string" || typeof value !== "string") return false;
  const normalizedPattern = pattern.trim().toLowerCase();
  if (!normalizedPattern) return false;
  const text = value.toLowerCase();
  let patternIndex = 0;
  let textIndex = 0;
  let starIndex = -1;
  let matchIndex = 0;

  while (textIndex < text.length) {
    if (patternIndex < normalizedPattern.length && normalizedPattern[patternIndex] === "*") {
      starIndex = patternIndex;
      matchIndex = textIndex;
      patternIndex += 1;
    } else if (patternIndex < normalizedPattern.length && normalizedPattern[patternIndex] === text[textIndex]) {
      patternIndex += 1;
      textIndex += 1;
    } else if (starIndex !== -1) {
      patternIndex = starIndex + 1;
      matchIndex += 1;
      textIndex = matchIndex;
    } else {
      return false;
    }
  }
  while (patternIndex < normalizedPattern.length && normalizedPattern[patternIndex] === "*") {
    patternIndex += 1;
  }
  return patternIndex === normalizedPattern.length;
}

export function matchesExtension(name, extensions) {
  if (!Array.isArray(extensions) || extensions.length === 0) return true;
  if (typeof name !== "string" || !name.includes(".")) return false;
  const ext = name.split(".").pop()?.trim().toLowerCase();
  return Boolean(ext && extensions.includes(ext));
}

export function normalizeExtensions(raw) {
  const source = Array.isArray(raw) ? raw.join(",") : String(raw ?? "");
  const seen = new Set();
  const result = [];
  for (const token of source.split(/[\s,]+/)) {
    const cleaned = token.trim().replace(/^\.+/, "").toLowerCase();
    if (cleaned && !seen.has(cleaned)) {
      seen.add(cleaned);
      result.push(cleaned);
    }
  }
  return result;
}

export function normalizeIgnoredPatterns(raw) {
  const source = Array.isArray(raw) ? raw.join("\n") : String(raw ?? "");
  const seen = new Set();
  const result = [];
  for (const line of source.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed && !seen.has(trimmed)) {
      seen.add(trimmed);
      result.push(trimmed);
    }
  }
  return result;
}

export function parseContentDispositionName(disposition, url) {
  if (typeof disposition === "string" && disposition) {
    const rfc5987 = /filename\*\s*=\s*(?:UTF-8|utf-8)''([^;\r\n]+)/i.exec(disposition);
    if (rfc5987?.[1]) {
      const raw = rfc5987[1].trim().replace(/^"|"$/g, "");
      try { return decodeURIComponent(raw); } catch { return raw; }
    }
    const quoted = /filename\s*=\s*"([^"]+)"/i.exec(disposition);
    if (quoted?.[1]) return quoted[1].trim();
    const plain = /filename\s*=\s*([^;\r\n]+)/i.exec(disposition);
    if (plain?.[1]) return plain[1].trim().replace(/^"|"$/g, "");
  }
  try {
    return decodeURIComponent(new URL(url).pathname.split("/").pop() || "");
  } catch {
    return "";
  }
}

export function formatBytes(bytes) {
  const value = Number(bytes);
  if (!Number.isFinite(value) || value <= 0) return "0 B";
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let current = value;
  let index = 0;
  while (current >= 1024 && index < units.length - 1) {
    current /= 1024;
    index += 1;
  }
  return index === 0 ? `${Math.round(current)} B` : `${current.toFixed(current >= 100 ? 0 : 1)} ${units[index]}`;
}

export function formatSpeed(bytesPerSecond) {
  const value = Number(bytesPerSecond);
  if (!Number.isFinite(value) || value <= 0) return "—";
  return `${formatBytes(value)}/s`;
}

export function formatEta(seconds) {
  const value = Number(seconds);
  if (!Number.isFinite(value) || value <= 0) return "—";
  const total = Math.floor(value);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const rem = total % 60;
  if (hours > 0) return `${hours}h ${minutes}m`;
  if (minutes > 0) return `${minutes}m ${rem}s`;
  return `${rem}s`;
}

export function computeRequestDeadlineMs(nowMs, waitLimitMs) {
  const safeNow = Number.isFinite(nowMs) ? Math.floor(nowMs) : Date.now();
  const safeWait = Number.isFinite(waitLimitMs) ? Math.max(1, Math.floor(waitLimitMs)) : 120_000;
  const margin = Math.min(2000, Math.floor(safeWait / 4));
  return safeNow + Math.max(250, safeWait - margin);
}
