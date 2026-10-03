import {DownloadRequestItem} from "~/interfaces/DownloadRequestItem";

export function getLinksFromSelection(selection:Selection): Array<DownloadRequestItem> {
    const links: Set<HTMLAnchorElement> = new Set()
    const downloadPage = document.location.href
    for (let i = 0; i < selection.rangeCount; i++) {
        const commonAncestor = selection.getRangeAt(i).commonAncestorContainer
        let root = isElementNode(commonAncestor) ? commonAncestor : commonAncestor.parentElement
        if (!root) continue

        // A selection consisting of the link label has a Text node as its
        // common ancestor. Include the enclosing anchor as well as links
        // nested under an element selection.
        if (root.matches("a[href]")) links.add(root as HTMLAnchorElement)
        for (const link of root.querySelectorAll<HTMLAnchorElement>("a[href]")) {
            links.add(link)
        }

        if (!isElementNode(commonAncestor)) {
            for (let ancestor = root.parentElement; ancestor; ancestor = ancestor.parentElement) {
                if (ancestor.matches("a[href]")) {
                    links.add(ancestor as HTMLAnchorElement)
                    break
                }
            }
        }
    }

    return [...links]
        .filter(link => selection.containsNode(link, true) && Boolean(link.href))
        .map(link => ({
            link: link.href,
            headers: null,
            description: link.innerText,
            downloadPage,
            suggestedName: null,
            type: "http"
        }))
}

function isElementNode(node: Node): node is Element {
    return node.nodeType === Node.ELEMENT_NODE
}
