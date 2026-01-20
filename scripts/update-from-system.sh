#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES="$(dirname "$SCRIPT_DIR")/home"

echo "=== Updating dotfiles from system ==="
echo ""

echo "[1/5] Updating shell configs..."
cp ~/.bashrc "$DOTFILES/"
cp ~/.bash_profile "$DOTFILES/"
cp ~/.bash_aliases "$DOTFILES/"

echo "[2/5] Updating editor configs..."
cp ~/.config/nvim/init.lua "$DOTFILES/.config/nvim/"
cp ~/.config/nvim/lazy-lock.json "$DOTFILES/.config/nvim/"
rm -rf "$DOTFILES/.config/nvim/lua"
cp -r ~/.config/nvim/lua "$DOTFILES/.config/nvim/"
cp ~/.config/zed/settings.json "$DOTFILES/.config/zed/"

echo "[3/5] Updating KDE configs..."
cp ~/.config/kdeglobals "$DOTFILES/.config/kde/"
cp ~/.config/kwinrc "$DOTFILES/.config/kde/"
cp ~/.config/kglobalshortcutsrc "$DOTFILES/.config/kde/"
cp ~/.config/plasmashellrc "$DOTFILES/.config/kde/"

echo "[4/5] Updating package lists..."
pacman -Qqen > "$SCRIPT_DIR/pkglist-official.txt"
pacman -Qqem > "$SCRIPT_DIR/pkglist-aur.txt"

echo "[5/5] Updating Claude configs..."
cp ~/.claude/CLAUDE.md "$DOTFILES/.claude/"
cp ~/.claude/settings.json "$DOTFILES/.claude/"

echo ""
echo "=== Update complete ==="
echo "Review changes with: cd ~/dotfiles && git diff"
echo "Commit with: git add -A && git commit -m 'Update configs'"
