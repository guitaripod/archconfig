# Dotfiles

Arch Linux configuration files for syncing between machines.

## Prerequisites

- Enable multilib in /etc/pacman.conf (for gaming packages)
- SSH key configured for GitHub

## Fresh Install (New Machine)

1. Clone this repo:
   ```bash
   git clone git@github.com:guitaripod/archconfig.git ~/dotfiles
   ```

2. Run the installer:
   ```bash
   cd ~/dotfiles
   chmod +x scripts/*.sh
   ./scripts/install.sh
   ```

3. Link the dotfiles:
   ```bash
   ./scripts/link.sh
   ```

4. Reboot.

## Syncing Changes

### Pull changes from repo:
```bash
cd ~/dotfiles
git pull
./scripts/link.sh
```

### Push local changes to repo:
```bash
cd ~/dotfiles
./scripts/update-from-system.sh
git add -A
git commit -m "Update configs"
git push
```

## What's Included

- Shell: bash configs, aliases, prompt
- Editors: vim, neovim, zed
- Git: config, global ignore
- Terminal: ghostty, btop
- Desktop: KDE Plasma theme, shortcuts
- System: keyd (Ctrl+J/K as arrow keys)
- Packages: official and AUR package lists
- Services: systemd enabled services list

## Steam Launch Options

MangoHud with OBS game capture:
```
MANGOHUD=1 MANGOHUD_CONFIG=full,toggle_hud=Control_L+Right mangohud obs-gamecapture %command%
```
