#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
DOTFILES="$ROOT/home"
HOST="$(cat /etc/hostname)"

capture_unless_linked() {
    [[ "$1" -ef "$2/$(basename "$1")" ]] || cp "$1" "$2/"
}

echo "=== Updating dotfiles from system ==="
echo "Machine: $HOST"
echo ""

echo "[1/6] Updating shell configs..."
if [[ "$HOST" == arch ]]; then
    capture_unless_linked ~/.bashrc "$DOTFILES"
    capture_unless_linked ~/.bash_profile "$DOTFILES"
    capture_unless_linked ~/.bash_aliases "$DOTFILES"
else
    echo "  Skipped shared shell configs (arch only; edit the repo instead)"
fi

echo "[2/6] Updating editor configs..."
capture_unless_linked ~/.config/zed/settings.json "$DOTFILES/.config/zed"

echo "[3/6] Updating KDE configs..."
cp ~/.config/kdeglobals "$DOTFILES/.config/kde/"
cp ~/.config/kwinrc "$DOTFILES/.config/kde/"
cp ~/.config/kglobalshortcutsrc "$DOTFILES/.config/kde/"
cp ~/.config/kwinrulesrc "$DOTFILES/.config/kde/"
cp ~/.config/plasmashellrc "$DOTFILES/.config/kde/"
cp ~/.config/khotkeysrc "$DOTFILES/.config/kde/"
cp ~/.config/klipperrc "$DOTFILES/.config/kde/"
cp ~/.config/kcminputrc "$DOTFILES/.config/"

echo "[4/6] Updating SSH config..."
capture_unless_linked ~/.ssh/config "$DOTFILES/.ssh"

echo "[5/6] Updating package lists..."
if [[ "$HOST" == arch ]]; then
    pacman -Qqen > "$SCRIPT_DIR/pkglist-official.txt"
    pacman -Qqem > "$SCRIPT_DIR/pkglist-aur.txt"
else
    echo "  Skipped shared package lists (arch only; edit them on arch)"
fi

if [[ "$HOST" == "x1carbon" ]]; then
    echo "[5b/6] Updating x1carbon fingerprint PAM configs..."
    for f in sudo su su-l polkit-1 system-local-login sddm kde; do
        cp "/etc/pam.d/$f" "$ROOT/etc/x1carbon/pam.d/$f"
    done
fi

echo "[6/6] Updating circadia + ThemeSwitch + emulator configs..."
capture_unless_linked ~/.config/circadia/config.toml "$DOTFILES/.config/circadia"
cp ~/.config/emojipick/config.toml "$DOTFILES/.config/emojipick/"
capture_unless_linked ~/.config/ThemeSwitch/settings.json "$DOTFILES/.config/ThemeSwitch"
cp ~/.config/systemd/user/themeswitch.service "$DOTFILES/.config/systemd/user/"
cp ~/.config/rpcs3/config.yml "$DOTFILES/.config/rpcs3/"
cp ~/.config/rpcs3/evdev_positive_axis.yml "$DOTFILES/.config/rpcs3/"
rm -rf "$DOTFILES/.config/rpcs3/custom_configs"
mkdir -p "$DOTFILES/.config/rpcs3/custom_configs"
cp ~/.config/rpcs3/custom_configs/*.yml "$DOTFILES/.config/rpcs3/custom_configs/"
cp ~/.config/rpcs3/GuiConfigs/CurrentSettings.ini "$DOTFILES/.config/rpcs3/GuiConfigs/"
cp ~/.config/rpcs3/GuiConfigs/persistent_settings.dat "$DOTFILES/.config/rpcs3/GuiConfigs/"
cp ~/.config/PCSX2/inis/PCSX2.ini "$DOTFILES/.config/PCSX2/inis/"
for f in Dolphin GCKeyNew GCPadNew GFX Qt WiimoteNew; do
    cp ~/.config/dolphin-emu/$f.ini "$DOTFILES/.config/dolphin-emu/"
done
cp ~/.config/Cemu/settings.xml "$DOTFILES/.config/Cemu/"
rm -rf "$DOTFILES/.config/Cemu/controllerProfiles"
cp -r ~/.config/Cemu/controllerProfiles "$DOTFILES/.config/Cemu/"

echo ""
echo "=== Update complete ==="
echo "Review changes with: cd ~/dotfiles && git diff"
echo "Commit with: git add -A && git commit -m 'Update configs'"
