const STEP = 0.6;
const MAX_ZOOM = 5.0;

chrome.runtime.onMessage.addListener((msg, sender) => {
    if (msg?.type !== "zoom-in-60") return;
    const tabId = sender.tab?.id;
    if (!tabId) return;
    chrome.tabs.getZoom(tabId).then((current) => {
        const next = Math.min(current + STEP, MAX_ZOOM);
        if (next === current) return;
        chrome.tabs.setZoom(tabId, next);
    });
});
