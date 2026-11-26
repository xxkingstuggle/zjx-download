import test from "node:test";
import assert from "node:assert/strict";
import {DEFAULTS, validPort} from "../src/storage.js";
import {decodeAcceptance} from "../src/app-api.js";
import {
  computeRequestDeadlineMs,
  formatBytes,
  formatEta,
  formatSpeed,
  isHttpUrl,
  matchesExtension,
  normalizeExtensions,
  normalizeIgnoredPatterns,
  parseContentDispositionName,
  wildcardMatch
} from "../src/utils.js";

test("storage DEFAULTS includes apiRequiresKey and validates port bounds", () => {
  assert.equal(DEFAULTS.apiRequiresKey, false);
  assert.equal(validPort(1023), false);
  assert.equal(validPort(1024), true);
  assert.equal(validPort(15151), true);
  assert.equal(validPort(65535), true);
  assert.equal(validPort(65536), false);
  assert.equal(validPort("15151.5"), false);
  assert.equal(validPort("abc"), false);
});

test("utils validates HTTP(S) URLs and matches wildcards without regex pitfalls", () => {
  assert.equal(isHttpUrl("https://example.com/file.zip"), true);
  assert.equal(isHttpUrl("http://127.0.0.1:15151/ping"), true);
  assert.equal(isHttpUrl("chrome://extensions"), false);
  assert.equal(isHttpUrl("javascript:alert(1)"), false);
  assert.equal(isHttpUrl(""), false);

  assert.equal(wildcardMatch("*.example.com/*", "https://cdn.example.com/a.zip"), true);
  assert.equal(wildcardMatch("https://example.com/private/*", "https://EXAMPLE.COM/private/doc.pdf"), true);
  assert.equal(wildcardMatch("*alpha*beta*", "xx-alpha-mid-beta-yy"), true);
  assert.equal(wildcardMatch("*alpha*beta*", "xx-beta-alpha-yy"), false);
  assert.equal(wildcardMatch("", "https://example.com"), false);
});

test("utils normalizes extensions, ignored patterns, and parses RFC 5987 Content-Disposition", () => {
  assert.deepEqual(normalizeExtensions(".ZIP, dmg  .Tar.Gz, zip"), ["zip", "dmg", "tar.gz"]);
  assert.deepEqual(normalizeIgnoredPatterns(" *.local/* \n\n https://a.test/* \n*.local/*"), ["*.local/*", "https://a.test/*"]);
  assert.equal(matchesExtension("archive.ZIP", ["zip", "dmg"]), true);
  assert.equal(matchesExtension("README", ["zip"]), false);

  assert.equal(
    parseContentDispositionName("attachment; filename*=UTF-8''%E6%B5%8B%E8%AF%95%20%E6%96%87%E4%BB%B6.zip", "https://example.com/dl"),
    "测试 文件.zip"
  );
  assert.equal(
    parseContentDispositionName('attachment; filename="installer.dmg"', "https://example.com/dl"),
    "installer.dmg"
  );
  assert.equal(
    parseContentDispositionName("", "https://example.com/files/hello%20world.iso"),
    "hello world.iso"
  );
});

test("utils formats bytes, speed, ETA and guards short request deadlines", () => {
  assert.equal(formatBytes(0), "0 B");
  assert.equal(formatBytes(1536), "1.5 KiB");
  assert.equal(formatSpeed(0), "—");
  assert.equal(formatSpeed(2 * 1024 * 1024), "2.0 MiB/s");
  assert.equal(formatEta(0), "—");
  assert.equal(formatEta(75), "1m 15s");
  assert.equal(formatEta(3661), "1h 1m");

  const now = 1_700_000_000_000;
  assert.ok(computeRequestDeadlineMs(now, 1000) > now);
  assert.ok(computeRequestDeadlineMs(now, 500) > now);
  assert.equal(computeRequestDeadlineMs(now, 120_000), now + 118_000);
});

test("decodeAcceptance validates receipts and rejects malformed payloads", () => {
  const valid = decodeAcceptance(
    JSON.stringify({
      requestId: "req-1",
      accepted: true,
      acceptedCount: 1,
      acceptedTaskIDs: [101],
      items: [{index: 0, taskID: 101, error: null}]
    }),
    "req-1",
    1
  );
  assert.equal(valid.accepted, true);
  assert.deepEqual(valid.acceptedTaskIDs, [101]);
  assert.equal(valid.declined, false);

  const declined = decodeAcceptance(
    JSON.stringify({
      requestId: "req-2",
      accepted: false,
      acceptedCount: 0,
      acceptedTaskIDs: [],
      declined: true,
      items: [{index: 0, taskID: null, error: "用户拒绝了此请求。"}]
    }),
    "req-2",
    1
  );
  assert.equal(declined.accepted, false);
  assert.equal(declined.declined, true);

  assert.throws(() => decodeAcceptance(
    JSON.stringify({
      requestId: "wrong-id",
      accepted: true,
      acceptedCount: 1,
      acceptedTaskIDs: [1],
      items: [{index: 0, taskID: 1, error: null}]
    }),
    "req-3",
    1
  ));

  assert.throws(() => decodeAcceptance(
    JSON.stringify({
      requestId: "req-4",
      accepted: true,
      acceptedCount: 1,
      acceptedTaskIDs: [1],
      declined: true,
      items: [{index: 0, taskID: 1, error: null}]
    }),
    "req-4",
    1
  ));
});
