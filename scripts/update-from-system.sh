#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES="$(dirname "$SCRIPT_DIR")/home"

echo "=== Updating dotfiles from system ==="
echo ""

echo "[1/7] Updating shell configs..."
cp ~/.bashrc "$DOTFILES/"
cp ~/.bash_profile "$DOTFILES/"
cp ~/.bash_aliases "$DOTFILES/"

echo "[2/7] Updating editor configs..."
cp ~/.config/nvim/init.lua "$DOTFILES/.config/nvim/"
cp ~/.config/nvim/lazy-lock.json "$DOTFILES/.config/nvim/"
rm -rf "$DOTFILES/.config/nvim/lua"
cp -r ~/.config/nvim/lua "$DOTFILES/.config/nvim/"
cp ~/.config/zed/settings.json "$DOTFILES/.config/zed/"

echo "[3/7] Updating KDE configs..."
cp ~/.config/kdeglobals "$DOTFILES/.config/kde/"
cp ~/.config/kwinrc "$DOTFILES/.config/kde/"
cp ~/.config/kglobalshortcutsrc "$DOTFILES/.config/kde/"
cp ~/.config/plasmashellrc "$DOTFILES/.config/kde/"
cp ~/.config/khotkeysrc "$DOTFILES/.config/kde/"
cp ~/.config/kcminputrc "$DOTFILES/.config/"

echo "[4/7] Updating SSH config..."
cp ~/.ssh/config "$DOTFILES/.ssh/"

echo "[5/7] Updating package lists..."
pacman -Qqen > "$SCRIPT_DIR/pkglist-official.txt"
pacman -Qqem > "$SCRIPT_DIR/pkglist-aur.txt"

echo "[6/7] Updating Claude configs..."
cp ~/.claude/CLAUDE.md "$DOTFILES/.claude/"
cp ~/.claude/settings.json "$DOTFILES/.claude/"

echo "[7/7] Updating emulator configs..."
cp ~/.config/rpcs3/config.yml "$DOTFILES/.config/rpcs3/"
cp ~/.config/rpcs3/evdev_positive_axis.yml "$DOTFILES/.config/rpcs3/"
rm -rf "$DOTFILES/.config/rpcs3/custom_configs"
cp -r ~/.config/rpcs3/custom_configs "$DOTFILES/.config/rpcs3/"
cp ~/.config/rpcs3/GuiConfigs/CurrentSettings.ini "$DOTFILES/.config/rpcs3/GuiConfigs/"
cp ~/.config/rpcs3/GuiConfigs/persistent_settings.dat "$DOTFILES/.config/rpcs3/GuiConfigs/"
cp ~/.config/PCSX2/inis/PCSX2.ini "$DOTFILES/.config/PCSX2/inis/"
cp ~/.config/dolphin-emu/*.ini "$DOTFILES/.config/dolphin-emu/"
cp ~/.config/Cemu/settings.xml "$DOTFILES/.config/Cemu/"
rm -rf "$DOTFILES/.config/Cemu/controllerProfiles"
cp -r ~/.config/Cemu/controllerProfiles "$DOTFILES/.config/Cemu/"

echo ""
echo "=== Update complete ==="
echo "Review changes with: cd ~/dotfiles && git diff"
echo "Commit with: git add -A && git commit -m 'Update configs'"
