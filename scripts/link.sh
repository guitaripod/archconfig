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

echo "[1/11] Linking shell configs..."
link_file "$DOTFILES/.bashrc" "$HOME/.bashrc"
link_file "$DOTFILES/.bash_profile" "$HOME/.bash_profile"
link_file "$DOTFILES/.bash_aliases" "$HOME/.bash_aliases"
link_file "$DOTFILES/.bash_logout" "$HOME/.bash_logout"

echo "[2/11] Linking editor configs..."
link_file "$DOTFILES/.vimrc" "$HOME/.vimrc"
mkdir -p "$HOME/.config/nvim"
ln -sf "$DOTFILES/.config/nvim/init.lua" "$HOME/.config/nvim/"
ln -sf "$DOTFILES/.config/nvim/lazy-lock.json" "$HOME/.config/nvim/"
rm -rf "$HOME/.config/nvim/lua"
cp -r "$DOTFILES/.config/nvim/lua" "$HOME/.config/nvim/"
mkdir -p "$HOME/.config/zed"
link_file "$DOTFILES/.config/zed/settings.json" "$HOME/.config/zed/settings.json"

echo "[3/11] Linking git configs..."
link_file "$DOTFILES/.gitconfig" "$HOME/.gitconfig"
mkdir -p "$HOME/.config/git"
link_file "$DOTFILES/.config/git/ignore" "$HOME/.config/git/ignore"

echo "[4/11] Linking terminal configs..."
if [[ -d "$HOME/.config/ghostty/.git" ]]; then
    git -C "$HOME/.config/ghostty" pull
else
    rm -rf "$HOME/.config/ghostty"
    git clone git@github.com:guitaripod/ghostty-config.git "$HOME/.config/ghostty"
fi
mkdir -p "$HOME/.config/btop"
link_file "$DOTFILES/.config/btop/btop.conf" "$HOME/.config/btop/btop.conf"

echo "[5/11] Linking Claude Code configs..."
mkdir -p "$HOME/.claude"
link_file "$DOTFILES/.claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
link_file "$DOTFILES/.claude/settings.json" "$HOME/.claude/settings.json"

echo "[6/11] Copying KDE configs (no symlinks - KDE overwrites them)..."
cp "$DOTFILES/.config/kde/kdeglobals" "$HOME/.config/"
cp "$DOTFILES/.config/kde/kwinrc" "$HOME/.config/"
cp "$DOTFILES/.config/kde/kglobalshortcutsrc" "$HOME/.config/"
cp "$DOTFILES/.config/kde/plasmashellrc" "$HOME/.config/"
cp "$DOTFILES/.config/kde/khotkeysrc" "$HOME/.config/"
cp "$DOTFILES/.config/kde/klipperrc" "$HOME/.config/"
cp "$DOTFILES/.config/kcminputrc" "$HOME/.config/"

echo "[7/11] Linking SSH config..."
mkdir -p "$HOME/.ssh"
link_file "$DOTFILES/.ssh/config" "$HOME/.ssh/config"

echo "[8/11] Linking XDG configs..."
link_file "$DOTFILES/.config/mimeapps.list" "$HOME/.config/mimeapps.list"
link_file "$DOTFILES/.config/user-dirs.dirs" "$HOME/.config/user-dirs.dirs"

echo "[9/11] Linking autostart entries..."
mkdir -p "$HOME/.config/autostart"
link_file "$DOTFILES/.config/autostart/xmousepasteblock.desktop" "$HOME/.config/autostart/xmousepasteblock.desktop"

echo "[10/11] Installing custom scripts..."
mkdir -p "$HOME/.local/bin"
cp "$SCRIPT_DIR/toggle-perf.sh" "$HOME/.local/bin/toggle-perf"
chmod +x "$HOME/.local/bin/toggle-perf"

echo "[11/11] Copying emulator configs (no symlinks - emulators overwrite them)..."
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
