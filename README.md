# Dotfiles

Arch Linux configuration files for syncing between machines.

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

## Secrets

API keys are NOT stored in this repo. After cloning, manually add:
- `OPENAI_API_KEY` to `~/.bashrc`
- `OLLAMA_API_KEY` to `~/.bashrc`
- Set up `~/.wakatime.cfg` with your API key
