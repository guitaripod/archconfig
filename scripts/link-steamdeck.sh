#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES="$(dirname "$SCRIPT_DIR")/home"

echo "=== Steam Deck Dotfiles Linker ==="
echo "Source: $DOTFILES"
echo "Target: $HOME"
echo ""

link_file() {
    local src="$1"
    local dst="$2"

    if [[ -e "$dst" && ! -L "$dst" ]]; then
        echo "  Backing up existing: $dst -> $dst.backup"
        mv "$dst" "$dst.backup"
    fi

    mkdir -p "$(dirname "$dst")"
    ln -sf "$src" "$dst"
    echo "  Linked: $dst"
}

clone_or_pull() {
    local url="$1"
    local dst="$2"

    if [[ -d "$dst/.git" ]]; then
        git -C "$dst" pull --ff-only
    else
        rm -rf "$dst"
        git clone "$url" "$dst"
    fi
}

have() {
    command -v "$1" > /dev/null 2>&1
}

install_script() {
    local name="$1"
    local dep="$2"

    if ! have "$dep"; then
        echo "  Skipped $name (no $dep)"
        return
    fi

    cp "$SCRIPT_DIR/$name.sh" "$HOME/.local/bin/$name"
    chmod +x "$HOME/.local/bin/$name"
    echo "  Installed: $HOME/.local/bin/$name"
}

echo "[1/7] Linking shell configs..."
link_file "$DOTFILES/.bashrc" "$HOME/.bashrc"
link_file "$DOTFILES/.bash_profile" "$HOME/.bash_profile"
link_file "$DOTFILES/.bash_aliases" "$HOME/.bash_aliases"
link_file "$DOTFILES/.bash_logout" "$HOME/.bash_logout"

echo "[2/7] Linking git configs..."
link_file "$DOTFILES/.gitconfig" "$HOME/.gitconfig"
link_file "$DOTFILES/.config/git/ignore" "$HOME/.config/git/ignore"

echo "[3/7] Linking SSH config..."
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
link_file "$DOTFILES/.ssh/config" "$HOME/.ssh/config"

echo "[4/7] Linking terminal configs..."
clone_or_pull "https://github.com/guitaripod/ghostty-config.git" "$HOME/.config/ghostty"
MACHINE_CONFIG="$HOME/.config/ghostty/machines/$(cat /etc/hostname)"
if [[ -f "$MACHINE_CONFIG" ]]; then
    ln -sf "machines/$(cat /etc/hostname)" "$HOME/.config/ghostty/local"
fi
link_file "$DOTFILES/.config/btop/btop.conf" "$HOME/.config/btop/btop.conf"

echo "[5/7] Linking editor configs..."
link_file "$DOTFILES/.vimrc" "$HOME/.vimrc"
if have nvim; then
    clone_or_pull "https://github.com/guitaripod/rawdog.ml.nvim.git" "$HOME/.config/nvim"
else
    echo "  Skipped nvim config (nvim not installed)"
fi
if have zed; then
    link_file "$DOTFILES/.config/zed/settings.json" "$HOME/.config/zed/settings.json"
else
    echo "  Skipped zed settings (zed not installed)"
fi

echo "[6/7] Setting up Claude Code config (claudeconfig)..."
clone_or_pull "https://github.com/guitaripod/claudeconfig.git" "$HOME/claudeconfig"
"$HOME/claudeconfig/scripts/link.sh"

echo "[7/7] Installing custom scripts..."
mkdir -p "$HOME/.local/bin"
link_file "$DOTFILES/.config/user-dirs.dirs" "$HOME/.config/user-dirs.dirs"
install_script toggle-perf cpupower
install_script guitar guitarix
install_script tailsend tailscale
install_script qbt-add qbittorrent-nox
install_script clip-to-twitter yt-dlp
install_script ufc-rss-fetch yt-dlp

echo ""
echo "Skipped (not applicable to SteamOS):"
echo "  mimeapps.list  - handlers reference apps not installed on the Deck"
echo "  KDE configs    - Deck Desktop Mode has its own display/panel setup"
echo "  emulators      - EmuDeck manages RPCS3/PCSX2/Dolphin/Cemu here"
echo "  pipewire       - low-latency profile is tuned for the desktop interface"
echo "  systemd units  - circadia/obsbot/qbittorrent/themeswitch not on the Deck"
echo "  etc/           - immutable root filesystem"
echo ""
echo "=== Steam Deck linking complete ==="
echo "Restart your shell or run: source ~/.bashrc"
