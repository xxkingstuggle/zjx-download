const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")
const ts = require("typescript")

const sourcePath = path.join(__dirname, "../src/utils/LinkExtractor.ts")
const source = fs.readFileSync(sourcePath, "utf8")
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText
const compiledModule = { exports: {} }
vm.runInNewContext(compiled, {
  exports: compiledModule.exports,
  module: compiledModule,
  require,
  Node: { ELEMENT_NODE: 1 },
  document: { location: { href: "http://fixture.test/page" } }
})
const { getLinksFromSelection } = compiledModule.exports

function element({ href = "", innerText = "", children = [] } = {}) {
  const value = {
    nodeType: 1,
    href,
    innerText,
    parentElement: null,
    children,
    matches(selector) { return selector === "a[href]" && Boolean(this.href) },
    querySelectorAll(selector) {
      if (selector !== "a[href]") return []
      return this.children.flatMap(child => [
        ...(child.matches?.("a[href]") ? [child] : []),
        ...child.querySelectorAll?.("a[href]") ?? []
      ])
    }
  }
  for (const child of children) child.parentElement = value
  return value
}

function selection(commonAncestor, included) {
  return {
    rangeCount: 1,
    getRangeAt() { return { commonAncestorContainer: commonAncestor } },
    containsNode(node) { return included.has(node) }
  }
}

const link = element({ href: "http://fixture.test/selected.bin", innerText: "Selected file" })
const text = { nodeType: 3, parentElement: link }
assert.deepEqual(
  Array.from(getLinksFromSelection(selection(text, new Set([link]))), item => item.link),
  ["http://fixture.test/selected.bin"],
  "selecting only an anchor's text must return its enclosing link"
)

const first = element({ href: "http://fixture.test/first.bin", innerText: "First" })
const second = element({ href: "http://fixture.test/second.bin", innerText: "Second" })
const outside = element({ href: "http://fixture.test/outside.bin", innerText: "Outside" })
const container = element({ children: [first, second, outside] })
assert.deepEqual(
  Array.from(getLinksFromSelection(selection(container, new Set([first, second]))), item => item.link),
  ["http://fixture.test/first.bin", "http://fixture.test/second.bin"],
  "an element range must include selected descendants and omit unselected links"
)

console.log("LinkExtractor selection tests passed (text-node anchor and multiple selected descendants).")
