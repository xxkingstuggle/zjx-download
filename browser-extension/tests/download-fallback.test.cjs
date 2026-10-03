const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")
const ts = require("typescript")

const sourcePath = path.join(__dirname, "../src/linkgrabber/RequestAcceptance.ts")
const source = fs.readFileSync(sourcePath, "utf8")
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText
const compiledModule = { exports: {} }
vm.runInNewContext(compiled, {
  exports: compiledModule.exports,
  module: compiledModule,
  require,
  Promise,
})
const { cancelBrowserDownloadOnlyAfterAcceptance, requestAppAcceptanceOnce } = compiledModule.exports

async function main() {
  const request = { calls: 0 }
  let resolveAcceptance
  const requestPromise = requestAppAcceptanceOnce(request, () => {
    request.calls += 1
    return new Promise(resolve => { resolveAcceptance = resolve })
  })
  const duplicatePromise = requestAppAcceptanceOnce(request, async () => {
    request.calls += 1
    return true
  })
  assert.equal(request.calls, 0, "request callback is deferred until the promise is installed")
  await Promise.resolve()
  assert.equal(request.calls, 1, "webRequest and downloads.onCreated share one app request")
  resolveAcceptance(false)
  assert.equal(await requestPromise, false)
  assert.equal(await duplicatePromise, false)

  const failed = { appAddPromise: Promise.resolve(false) }
  let canceled = false
  assert.equal(await cancelBrowserDownloadOnlyAfterAcceptance(
    failed,
    async () => true,
    async () => { canceled = true },
  ), false)
  assert.equal(canceled, false, "failed app handoff leaves Chrome's original download running")

  const accepted = { appAddPromise: Promise.resolve(true) }
  assert.equal(await cancelBrowserDownloadOnlyAfterAcceptance(
    accepted,
    async () => false,
    async () => { canceled = true },
  ), true)
  assert.equal(canceled, true, "accepted app handoff cancels Chrome's duplicate download")
}

main().then(() => {
  console.log("Chrome download fallback tests passed (deduplicated handoff and acceptance-gated cancellation).")
}).catch(error => {
  console.error(error)
  process.exitCode = 1
})
