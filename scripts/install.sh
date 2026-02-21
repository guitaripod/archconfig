#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Arch Linux Dotfiles Installer ==="
echo "Dotfiles directory: $DOTFILES_DIR"
echo ""

echo "[1/6] Installing official packages..."
sudo pacman -S --needed - < "$SCRIPT_DIR/pkglist-official.txt"

echo "[2/6] Installing yay (AUR helper)..."
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

echo "[3/6] Installing AUR packages..."
yay -S --needed - < "$SCRIPT_DIR/pkglist-aur.txt"

echo "[4/6] Installing oh-my-bash..."
if [[ ! -d "$HOME/.oh-my-bash" ]]; then
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)" --unattended
else
    echo "oh-my-bash already installed, skipping."
fi

echo "[5/6] Installing system configs..."
sudo mkdir -p /etc/keyd
sudo cp "$DOTFILES_DIR/etc/keyd/default.conf" /etc/keyd/
sudo cp "$DOTFILES_DIR/etc/systemd/system/nvidia-power-limit.service" /etc/systemd/system/
sudo mkdir -p /etc/default
sudo cp "$DOTFILES_DIR/etc/default/cpupower" /etc/default/

echo "[6/6] Enabling services..."
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
