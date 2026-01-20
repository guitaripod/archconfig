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

echo "[1/7] Linking shell configs..."
link_file "$DOTFILES/.bashrc" "$HOME/.bashrc"
link_file "$DOTFILES/.bash_profile" "$HOME/.bash_profile"
link_file "$DOTFILES/.bash_aliases" "$HOME/.bash_aliases"
link_file "$DOTFILES/.bash_logout" "$HOME/.bash_logout"

echo "[2/7] Linking editor configs..."
link_file "$DOTFILES/.vimrc" "$HOME/.vimrc"
mkdir -p "$HOME/.config/nvim"
ln -sf "$DOTFILES/.config/nvim/init.lua" "$HOME/.config/nvim/"
ln -sf "$DOTFILES/.config/nvim/lazy-lock.json" "$HOME/.config/nvim/"
rm -rf "$HOME/.config/nvim/lua"
cp -r "$DOTFILES/.config/nvim/lua" "$HOME/.config/nvim/"
mkdir -p "$HOME/.config/zed"
link_file "$DOTFILES/.config/zed/settings.json" "$HOME/.config/zed/settings.json"

echo "[3/7] Linking git configs..."
link_file "$DOTFILES/.gitconfig" "$HOME/.gitconfig"
mkdir -p "$HOME/.config/git"
link_file "$DOTFILES/.config/git/ignore" "$HOME/.config/git/ignore"

echo "[4/7] Linking terminal configs..."
mkdir -p "$HOME/.config/ghostty"
link_file "$DOTFILES/.config/ghostty/config" "$HOME/.config/ghostty/config"
mkdir -p "$HOME/.config/btop"
link_file "$DOTFILES/.config/btop/btop.conf" "$HOME/.config/btop/btop.conf"

echo "[5/7] Linking Claude Code configs..."
mkdir -p "$HOME/.claude"
link_file "$DOTFILES/.claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
link_file "$DOTFILES/.claude/settings.json" "$HOME/.claude/settings.json"

echo "[6/7] Copying KDE configs (no symlinks - KDE overwrites them)..."
cp "$DOTFILES/.config/kde/kdeglobals" "$HOME/.config/"
cp "$DOTFILES/.config/kde/kwinrc" "$HOME/.config/"
cp "$DOTFILES/.config/kde/kglobalshortcutsrc" "$HOME/.config/"
cp "$DOTFILES/.config/kde/plasmashellrc" "$HOME/.config/"

echo "[7/7] Linking GTK and XDG configs..."
link_file "$DOTFILES/.gtkrc-2.0" "$HOME/.gtkrc-2.0"
mkdir -p "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0"
cp -r "$DOTFILES/.config/gtk-3.0/"* "$HOME/.config/gtk-3.0/"
cp -r "$DOTFILES/.config/gtk-4.0/"* "$HOME/.config/gtk-4.0/"
link_file "$DOTFILES/.config/mimeapps.list" "$HOME/.config/mimeapps.list"
link_file "$DOTFILES/.config/user-dirs.dirs" "$HOME/.config/user-dirs.dirs"

echo ""
echo "=== Linking complete ==="
echo "Restart your shell or run: source ~/.bashrc"
