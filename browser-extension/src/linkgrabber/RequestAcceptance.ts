export type RequestAcceptanceHolder = {
    appAddPromise?: Promise<boolean>,
}

export function requestAppAcceptanceOnce(
    holder: RequestAcceptanceHolder,
    request: () => Promise<boolean>,
): Promise<boolean> {
    if (!holder.appAddPromise) {
        holder.appAddPromise = Promise.resolve().then(request)
    }
    return holder.appAddPromise
}

export async function cancelBrowserDownloadOnlyAfterAcceptance(
    holder: RequestAcceptanceHolder,
    request: () => Promise<boolean>,
    cancelBrowserDownload: () => Promise<void>,
): Promise<boolean> {
    const accepted = await requestAppAcceptanceOnce(holder, request)
    if (accepted) {
        await cancelBrowserDownload()
    }
    return accepted
}
