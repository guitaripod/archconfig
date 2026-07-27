#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES="$(dirname "$SCRIPT_DIR")/home"

echo "=== Dotfiles Linker ==="
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

    ln -sf "$src" "$dst"
    echo "  Linked: $dst"
}

has_nvidia_gpu() {
    [[ -e /proc/driver/nvidia/version ]]
}

echo "[1/14] Linking shell configs..."
link_file "$DOTFILES/.bashrc" "$HOME/.bashrc"
link_file "$DOTFILES/.bash_profile" "$HOME/.bash_profile"
link_file "$DOTFILES/.bash_aliases" "$HOME/.bash_aliases"
link_file "$DOTFILES/.bash_logout" "$HOME/.bash_logout"

echo "[2/14] Linking editor configs..."
link_file "$DOTFILES/.vimrc" "$HOME/.vimrc"
if [[ -d "$HOME/.config/nvim/.git" ]]; then
    git -C "$HOME/.config/nvim" pull
else
    rm -rf "$HOME/.config/nvim"
    git clone git@github.com:guitaripod/rawdog.ml.nvim.git "$HOME/.config/nvim"
fi
mkdir -p "$HOME/.config/zed"
link_file "$DOTFILES/.config/zed/settings.json" "$HOME/.config/zed/settings.json"

echo "[3/14] Linking git configs..."
link_file "$DOTFILES/.gitconfig" "$HOME/.gitconfig"
mkdir -p "$HOME/.config/git"
link_file "$DOTFILES/.config/git/ignore" "$HOME/.config/git/ignore"

echo "[4/14] Linking terminal configs..."
if [[ -d "$HOME/.config/ghostty/.git" ]]; then
    git -C "$HOME/.config/ghostty" pull
else
    rm -rf "$HOME/.config/ghostty"
    git clone git@github.com:guitaripod/ghostty-config.git "$HOME/.config/ghostty"
fi
MACHINE_CONFIG="$HOME/.config/ghostty/machines/$(cat /etc/hostname)"
if [[ -f "$MACHINE_CONFIG" ]]; then
    ln -sf "machines/$(cat /etc/hostname)" "$HOME/.config/ghostty/local"
fi
mkdir -p "$HOME/.config/btop"
link_file "$DOTFILES/.config/btop/btop.conf" "$HOME/.config/btop/btop.conf"

echo "[5/14] Setting up Claude Code config (claudeconfig)..."
if [[ -d "$HOME/claudeconfig/.git" ]]; then
    git -C "$HOME/claudeconfig" pull
else
    git clone git@github.com:guitaripod/claudeconfig.git "$HOME/claudeconfig"
fi
"$HOME/claudeconfig/scripts/link.sh"

echo "[6/14] Copying KDE configs (no symlinks - KDE overwrites them)..."
cp "$DOTFILES/.config/kde/kdeglobals" "$HOME/.config/"
cp "$DOTFILES/.config/kde/kwinrc" "$HOME/.config/"
cp "$DOTFILES/.config/kde/kglobalshortcutsrc" "$HOME/.config/"
cp "$DOTFILES/.config/kde/plasmashellrc" "$HOME/.config/"
cp "$DOTFILES/.config/kde/khotkeysrc" "$HOME/.config/"
cp "$DOTFILES/.config/kde/klipperrc" "$HOME/.config/"
cp "$DOTFILES/.config/kcminputrc" "$HOME/.config/"

echo "[7/14] Linking SSH config..."
mkdir -p "$HOME/.ssh"
link_file "$DOTFILES/.ssh/config" "$HOME/.ssh/config"

echo "[8/14] Linking XDG configs..."
link_file "$DOTFILES/.config/mimeapps.list" "$HOME/.config/mimeapps.list"
link_file "$DOTFILES/.config/user-dirs.dirs" "$HOME/.config/user-dirs.dirs"

echo "[9/14] Linking autostart entries..."
mkdir -p "$HOME/.config/autostart"
link_file "$DOTFILES/.config/autostart/xmousepasteblock.desktop" "$HOME/.config/autostart/xmousepasteblock.desktop"

echo "[10/14] Linking PipeWire configs..."
mkdir -p "$HOME/.config/pipewire/pipewire.conf.d"
link_file "$DOTFILES/.config/pipewire/pipewire.conf.d/10-low-latency.conf" "$HOME/.config/pipewire/pipewire.conf.d/10-low-latency.conf"

mkdir -p "$HOME/.config/circadia"
link_file "$DOTFILES/.config/circadia/config.toml" "$HOME/.config/circadia/config.toml"

mkdir -p "$HOME/.config/ThemeSwitch"
link_file "$DOTFILES/.config/ThemeSwitch/settings.json" "$HOME/.config/ThemeSwitch/settings.json"

echo "[11/14] Linking browser configs..."
if has_nvidia_gpu; then
    link_file "$DOTFILES/.config/vivaldi-stable.conf" "$HOME/.config/vivaldi-stable.conf"
else
    echo "  Skipped vivaldi-stable.conf (no NVIDIA GPU)"
fi

echo "[12/14] Installing custom scripts..."
mkdir -p "$HOME/.local/bin"
cp "$SCRIPT_DIR/toggle-perf.sh" "$HOME/.local/bin/toggle-perf"
chmod +x "$HOME/.local/bin/toggle-perf"
cp "$SCRIPT_DIR/guitar.sh" "$HOME/.local/bin/guitar"
chmod +x "$HOME/.local/bin/guitar"
cp "$SCRIPT_DIR/obsbot-fix-whitebalance.sh" "$HOME/.local/bin/obsbot-fix-whitebalance"
chmod +x "$HOME/.local/bin/obsbot-fix-whitebalance"
cp "$SCRIPT_DIR/tailsend.sh" "$HOME/.local/bin/tailsend"
chmod +x "$HOME/.local/bin/tailsend"
cp "$SCRIPT_DIR/qbt-add.sh" "$HOME/.local/bin/qbt-add"
chmod +x "$HOME/.local/bin/qbt-add"
cp "$SCRIPT_DIR/ufc-rss-fetch.sh" "$HOME/.local/bin/ufc-rss-fetch"
chmod +x "$HOME/.local/bin/ufc-rss-fetch"
cp "$SCRIPT_DIR/clip-to-twitter.sh" "$HOME/.local/bin/clip-to-twitter"
chmod +x "$HOME/.local/bin/clip-to-twitter"

mkdir -p "$HOME/.local/share/kio/servicemenus" "$HOME/.local/share/applications"
cp "$DOTFILES/.local/share/kio/servicemenus/tailsend.desktop" "$HOME/.local/share/kio/servicemenus/"
chmod +x "$HOME/.local/share/kio/servicemenus/tailsend.desktop"
cp "$DOTFILES/.local/share/applications/tailsend-clipboard.desktop" "$HOME/.local/share/applications/"
cp "$DOTFILES/.local/share/applications/qbittorrent-nox.desktop" "$HOME/.local/share/applications/"

echo "[13/14] Installing user services..."
mkdir -p "$HOME/.config/systemd/user"
cp "$DOTFILES/.config/systemd/user/obsbot-fix-whitebalance.service" "$HOME/.config/systemd/user/"
cp "$DOTFILES/.config/systemd/user/taildrop.service" "$HOME/.config/systemd/user/"
cp "$DOTFILES/.config/systemd/user/qbittorrent-nox.service" "$HOME/.config/systemd/user/"
cp "$DOTFILES/.config/systemd/user/ufc-rss-fetch.service" "$HOME/.config/systemd/user/"
cp "$DOTFILES/.config/systemd/user/ufc-rss-fetch.timer" "$HOME/.config/systemd/user/"
cp "$DOTFILES/.config/systemd/user/themeswitch.service" "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable obsbot-fix-whitebalance.service
systemctl --user enable circadia.service
systemctl --user enable taildrop.service
systemctl --user enable qbittorrent-nox.service
systemctl --user enable ufc-rss-fetch.timer
systemctl --user enable themeswitch.service

echo "[14/14] Copying emulator configs (no symlinks - emulators overwrite them)..."
mkdir -p "$HOME/.config/rpcs3/custom_configs" "$HOME/.config/rpcs3/GuiConfigs"
cp "$DOTFILES/.config/rpcs3/config.yml" "$HOME/.config/rpcs3/"
cp "$DOTFILES/.config/rpcs3/evdev_positive_axis.yml" "$HOME/.config/rpcs3/"
cp "$DOTFILES/.config/rpcs3/custom_configs/"*.yml "$HOME/.config/rpcs3/custom_configs/"
cp "$DOTFILES/.config/rpcs3/GuiConfigs/CurrentSettings.ini" "$HOME/.config/rpcs3/GuiConfigs/"
cp "$DOTFILES/.config/rpcs3/GuiConfigs/persistent_settings.dat" "$HOME/.config/rpcs3/GuiConfigs/"
mkdir -p "$HOME/.config/PCSX2/inis"
cp "$DOTFILES/.config/PCSX2/inis/PCSX2.ini" "$HOME/.config/PCSX2/inis/"
mkdir -p "$HOME/.config/dolphin-emu"
cp "$DOTFILES/.config/dolphin-emu/"*.ini "$HOME/.config/dolphin-emu/"
mkdir -p "$HOME/.config/Cemu/controllerProfiles"
cp "$DOTFILES/.config/Cemu/settings.xml" "$HOME/.config/Cemu/"
cp "$DOTFILES/.config/Cemu/controllerProfiles/"*.xml "$HOME/.config/Cemu/controllerProfiles/"

echo ""
echo "=== Linking complete ==="
echo "Restart your shell or run: source ~/.bashrc"
