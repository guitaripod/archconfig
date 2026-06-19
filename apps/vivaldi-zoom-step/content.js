const isMac =
    navigator.userAgentData?.platform === "macOS" ||
    /Mac/i.test(navigator.platform || "");

window.addEventListener(
    "keydown",
    (e) => {
        const primary = isMac ? e.metaKey : e.ctrlKey;
        const conflicting = isMac ? e.ctrlKey : e.metaKey;
        if (!primary || conflicting || e.altKey) return;
        if (e.key !== "+" && e.key !== "=") return;
        e.preventDefault();
        e.stopPropagation();
        chrome.runtime.sendMessage({ type: "zoom-in-60" });
    },
    true
);
