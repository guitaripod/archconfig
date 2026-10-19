#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(dirname "$SCRIPT_DIR")"
HOST="$(cat /etc/hostname)"

filter_packages() {
    if [[ "$HOST" == arch ]]; then
        cat
    else
        grep -Ev '^(lib32-|nvidia|steam$|steam-rom-manager-bin|mangohud|gamemode|gamescope|lutris|wine-staging|winetricks|protonup-qt|obs-studio$|obs-|obsbot-camera-control|upscayl-bin|plex-media-server|qbittorrent-nox|samba$|docker$|docker-compose|lazydocker-bin|ollama-cuda|onnxruntime-cuda|nvidia-container-toolkit|sunshine$|mprime$|r8125-dkms|cemu-bin|pcsx2-latest-bin|rpcs3-bin|ryujinx-bin|clonehero$)' || true
    fi
}

echo "=== Arch Linux Dotfiles Installer ==="
echo "Dotfiles directory: $DOTFILES_DIR"
echo "Machine: $HOST"
echo ""

echo "[1/6] Installing official packages..."
filter_packages < "$SCRIPT_DIR/pkglist-official.txt" | sudo pacman -S --needed -

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
filter_packages < "$SCRIPT_DIR/pkglist-aur.txt" | yay -S --needed -

echo "[4/6] Installing oh-my-bash..."
if [[ ! -d "$HOME/.oh-my-bash" ]]; then
    bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)" --unattended
else
    echo "oh-my-bash already installed, skipping."
fi

echo "[5/6] Installing system configs..."
sudo mkdir -p /etc/keyd
sudo cp "$DOTFILES_DIR/etc/keyd/default.conf" /etc/keyd/
sudo install -Dm 644 "$DOTFILES_DIR/etc/host-fw.nft" /etc/host-fw.nft
sudo install -Dm 644 "$DOTFILES_DIR/etc/systemd/system/host-fw.service" /etc/systemd/system/host-fw.service
sudo install -Dm 644 "$DOTFILES_DIR/etc/ssh/sshd_config.d/10-hardening.conf" /etc/ssh/sshd_config.d/10-hardening.conf
sudo install -Dm 644 "$DOTFILES_DIR/etc/sysctl.d/99-hardening.conf" /etc/sysctl.d/99-hardening.conf

if [[ "$HOST" == arch ]]; then
    sudo cp "$DOTFILES_DIR/etc/systemd/system/nvidia-power-limit.service" /etc/systemd/system/
    sudo mkdir -p /etc/default
    sudo cp "$DOTFILES_DIR/etc/default/cpupower-service.conf" /etc/default/
    sudo install -Dm 644 "$DOTFILES_DIR/etc/samba/smb.conf" /etc/samba/smb.conf
fi

if [[ "$HOST" == "x1carbon" ]]; then
    echo "  Installing x1carbon fingerprint PAM configs..."
    sudo install -m 644 "$DOTFILES_DIR/etc/x1carbon/pam.d/"* /etc/pam.d/
fi

echo "[6/7] Enabling services..."
SERVICE_LIST="$SCRIPT_DIR/enabled-services-$HOST.txt"
[[ -f "$SERVICE_LIST" ]] || SERVICE_LIST="$SCRIPT_DIR/enabled-services.txt"
while IFS= read -r service; do
    if [[ -n "$service" && ! "$service" =~ ^# ]]; then
        echo "  Enabling: $service"
        sudo systemctl enable "$service" 2>/dev/null || echo "    (skipped or already enabled)"
    fi
done < "$SERVICE_LIST"

echo "[7/7] Building ThemeSwitch (Qt6 + KF6 GlobalAccel)..."
mkdir -p "$HOME/Dev/cpp"
if [[ -d "$HOME/Dev/cpp/ThemeSwitch/.git" ]]; then
    git -C "$HOME/Dev/cpp/ThemeSwitch" pull
else
    git clone git@github.com:guitaripod/ThemeSwitch.git "$HOME/Dev/cpp/ThemeSwitch"
fi
cmake -S "$HOME/Dev/cpp/ThemeSwitch" -B "$HOME/Dev/cpp/ThemeSwitch/build"
cmake --build "$HOME/Dev/cpp/ThemeSwitch/build"
mkdir -p "$HOME/.local/bin"
ln -sf "$HOME/Dev/cpp/ThemeSwitch/build/ThemeSwitch" "$HOME/.local/bin/themeswitch"

echo ""
echo "=== Installation complete ==="
echo "Next: Run ./scripts/link.sh to symlink dotfiles"
echo "Then: Reboot to apply all changes"
