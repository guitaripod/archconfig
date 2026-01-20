#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Arch Linux Dotfiles Installer ==="
echo "Dotfiles directory: $DOTFILES_DIR"
echo ""

echo "[1/5] Installing official packages..."
sudo pacman -S --needed - < "$SCRIPT_DIR/pkglist-official.txt"

echo "[2/5] Installing yay (AUR helper)..."
if ! command -v yay &> /dev/null; then
    echo "yay not found, installing..."
    git clone https://aur.archlinux.org/yay.git /tmp/yay-install
    cd /tmp/yay-install
    makepkg -si --noconfirm
    cd -
    rm -rf /tmp/yay-install
else
    echo "yay already installed, skipping."
fi

echo "[3/5] Installing AUR packages..."
yay -S --needed - < "$SCRIPT_DIR/pkglist-aur.txt"

echo "[4/5] Installing system configs..."
sudo mkdir -p /etc/keyd
sudo cp "$DOTFILES_DIR/etc/keyd/default.conf" /etc/keyd/

echo "[5/5] Enabling services..."
while IFS= read -r service; do
    if [[ -n "$service" && ! "$service" =~ ^# ]]; then
        echo "  Enabling: $service"
        sudo systemctl enable "$service" 2>/dev/null || echo "    (skipped or already enabled)"
    fi
done < "$SCRIPT_DIR/enabled-services.txt"

echo ""
echo "=== Installation complete ==="
echo "Next: Run ./scripts/link.sh to symlink dotfiles"
echo "Then: Reboot to apply all changes"
