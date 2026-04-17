window.addEventListener(
    "keydown",
    (e) => {
        if (!e.ctrlKey || e.altKey || e.metaKey) return;
        if (e.key !== "+" && e.key !== "=") return;
        e.preventDefault();
        e.stopPropagation();
        chrome.runtime.sendMessage({ type: "zoom-in-60" });
    },
    true
);
