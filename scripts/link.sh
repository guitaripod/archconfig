#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES="$(dirname "$SCRIPT_DIR")/home"
HOST="$(cat /etc/hostname)"

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

# delegate: host.yml is a real per-machine file, not a symlink (see the delegate skill)
DELEGATE_OVERLAY="$DOTFILES/.config/delegate/machines/$HOST.yml"
if [[ -f "$DELEGATE_OVERLAY" ]]; then
    mkdir -p "$HOME/.config/delegate"
    rm -f "$HOME/.config/delegate/host.yml"
    install -Dm 644 "$DELEGATE_OVERLAY" "$HOME/.config/delegate/host.yml"
    echo "  Copied: $HOME/.config/delegate/host.yml"
else
    echo "  Skipped delegate overlay (no $DELEGATE_OVERLAY)"
fi

# opencode: per-machine models/MCPs overlay (shared config lives in claudeconfig)
OPENCODE_OVERLAY="$DOTFILES/.config/opencode/machines/$HOST.json"
if [[ -f "$OPENCODE_OVERLAY" ]]; then
    mkdir -p "$HOME/.config/opencode"
    link_file "$OPENCODE_OVERLAY" "$HOME/.config/opencode/opencode.local.json"
else
    echo "  Skipped opencode overlay (no $OPENCODE_OVERLAY)"
fi

echo "[5/14] Setting up Claude Code config (claudeconfig)..."
if [[ -d "$HOME/claudeconfig/.git" ]]; then
    git -C "$HOME/claudeconfig" pull
else
    git clone git@github.com:guitaripod/claudeconfig.git "$HOME/claudeconfig"
fi
"$HOME/claudeconfig/scripts/link.sh"
mkdir -p "$HOME/.claude/rules"
for rule in "$DOTFILES"/.claude/rules/*.md; do
    name="$(basename "$rule")"
    case "$name" in
        arch.md|local-models.md|zvec-grep.md)
            if [[ "$HOST" != arch ]]; then
                rm -f "$HOME/.claude/rules/$name"
                echo "  Skipped: $name (arch only)"
                continue
            fi
            ;;
        x1carbon.md)
            if [[ "$HOST" != x1carbon ]]; then
                rm -f "$HOME/.claude/rules/$name"
                echo "  Skipped: $name (x1carbon only)"
                continue
            fi
            ;;
    esac
    link_file "$rule" "$HOME/.claude/rules/$name"
done

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
rm -f "$HOME/.config/autostart/themeswitch.desktop"
link_file "$DOTFILES/.config/autostart/xmousepasteblock.desktop" "$HOME/.config/autostart/xmousepasteblock.desktop"

echo "[10/14] Linking PipeWire configs..."
mkdir -p "$HOME/.config/pipewire/pipewire.conf.d"
link_file "$DOTFILES/.config/pipewire/pipewire.conf.d/10-low-latency.conf" "$HOME/.config/pipewire/pipewire.conf.d/10-low-latency.conf"

mkdir -p "$HOME/.config/circadia"
link_file "$DOTFILES/.config/circadia/config.toml" "$HOME/.config/circadia/config.toml"

mkdir -p "$HOME/.config/ThemeSwitch"
link_file "$DOTFILES/.config/ThemeSwitch/settings.json" "$HOME/.config/ThemeSwitch/settings.json"

mkdir -p "$HOME/.config/mpv"
link_file "$DOTFILES/.config/mpv/mpv.conf" "$HOME/.config/mpv/mpv.conf"

echo "[11/14] Linking browser configs..."
if has_nvidia_gpu; then
    link_file "$DOTFILES/.config/vivaldi-stable.conf" "$HOME/.config/vivaldi-stable.conf"
else
    echo "  Skipped vivaldi-stable.conf (no NVIDIA GPU)"
fi

echo "[12/14] Installing custom scripts..."
mkdir -p "$HOME/.local/bin"
for script in toggle-perf guitar tailsend clip-to-twitter; do
    cp "$SCRIPT_DIR/$script.sh" "$HOME/.local/bin/$script"
    chmod +x "$HOME/.local/bin/$script"
done

if [[ "$HOST" == arch ]]; then
    for script in obsbot-fix-whitebalance qbt-add ufc-rss-fetch; do
        cp "$SCRIPT_DIR/$script.sh" "$HOME/.local/bin/$script"
        chmod +x "$HOME/.local/bin/$script"
    done
    for script in steam-taskbar-icons.py upscayl-watch.py; do
        dest="${script%.py}"
        cp "$SCRIPT_DIR/$script" "$HOME/.local/bin/$dest"
        chmod +x "$HOME/.local/bin/$dest"
    done
    mkdir -p "$HOME/.config/upscayl-watch" "$HOME/.local/state/upscayl-watch"
    [ -e "$HOME/.config/upscayl-watch/config.toml" ] || cp "$DOTFILES/.config/upscayl-watch/config.toml" "$HOME/.config/upscayl-watch/"
fi

mkdir -p "$HOME/.local/share/kio/servicemenus" "$HOME/.local/share/applications"
cp "$DOTFILES/.local/share/kio/servicemenus/tailsend.desktop" "$HOME/.local/share/kio/servicemenus/"
chmod +x "$HOME/.local/share/kio/servicemenus/tailsend.desktop"
cp "$DOTFILES/.local/share/applications/tailsend-clipboard.desktop" "$HOME/.local/share/applications/"

echo "[13/14] Installing user services..."
mkdir -p "$HOME/.config/systemd/user"
for unit in taildrop.service themeswitch.service; do
    cp "$DOTFILES/.config/systemd/user/$unit" "$HOME/.config/systemd/user/"
done

if [[ "$HOST" == arch ]]; then
    for unit in omp-auth-broker.service obsbot-fix-whitebalance.service \
        qbittorrent-nox.service ufc-rss-fetch.service ufc-rss-fetch.timer \
        steam-taskbar-icons.service steam-taskbar-icons.path upscayl-watch.service; do
        cp "$DOTFILES/.config/systemd/user/$unit" "$HOME/.config/systemd/user/"
    done
    cp "$DOTFILES/.local/share/applications/qbittorrent-nox.desktop" "$HOME/.local/share/applications/"
fi
systemctl --user daemon-reload
systemctl --user enable circadia.service taildrop.service themeswitch.service

if [[ "$HOST" == arch ]]; then
    systemctl --user enable obsbot-fix-whitebalance.service qbittorrent-nox.service \
        ufc-rss-fetch.timer steam-taskbar-icons.path upscayl-watch.service
else
    for unit in obsbot-fix-whitebalance.service qbittorrent-nox.service \
        ufc-rss-fetch.timer steam-taskbar-icons.path upscayl-watch.service; do
        systemctl --user disable --now "$unit" 2>/dev/null || true
        rm -f "$HOME/.config/systemd/user/$unit"
    done
    rm -f "$HOME/.local/bin/obsbot-fix-whitebalance" "$HOME/.local/bin/qbt-add" \
        "$HOME/.local/bin/ufc-rss-fetch" "$HOME/.local/bin/steam-taskbar-icons" \
        "$HOME/.local/bin/upscayl-watch"
    rm -f "$HOME/.local/share/applications/qbittorrent-nox.desktop"
    rm -rf "$HOME/.config/upscayl-watch" "$HOME/.local/state/upscayl-watch"
    systemctl --user daemon-reload
fi

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
