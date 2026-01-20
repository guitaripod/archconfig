# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# Enable the subsequent settings only in interactive sessions
case $- in
  *i*) ;;
    *) return;;
esac

# SSH agent
eval "$(ssh-agent -s)" > /dev/null
if ! pgrep -u "$USER" ssh-agent > /dev/null; then
    ssh-agent -t 24h > "$XDG_RUNTIME_DIR/ssh-agent.env"
fi
if [[ ! "$SSH_AUTH_SOCK" ]]; then
    source "$XDG_RUNTIME_DIR/ssh-agent.env" >/dev/null
fi

# Auto-load SSH key
ssh-add ~/.ssh/id_ed25519 2>/dev/null

# Path to your oh-my-bash installation.
export OSH='/home/marcus/.oh-my-bash'

# Add ~/.local/bin to PATH
export PATH="$HOME/.local/bin:$PATH"

alias ls='ls --color=auto'
alias grep='grep --color=auto'

# Function to get git branch and status
git_prompt() {
    # Check if we're in a git repo
    if git rev-parse --git-dir > /dev/null 2>&1; then
        # Get branch name
        local branch=$(git branch 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/\1/')
        
        # Get git status indicators
        local git_status=""
        
        # Check for uncommitted changes
        if [[ $(git status --porcelain 2> /dev/null) ]]; then
            git_status="${git_status}*"
        fi
        
        # Check for staged changes
        if git diff --cached --quiet 2> /dev/null; then
            :
        else
            git_status="${git_status}+"
        fi
        
        # Check if ahead/behind remote
        local upstream=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2> /dev/null)
        if [[ -n "$upstream" ]]; then
            local ahead=$(git rev-list @{u}..HEAD --count 2> /dev/null)
            local behind=$(git rev-list HEAD..@{u} --count 2> /dev/null)
            
            if [[ $ahead -gt 0 ]]; then
                git_status="${git_status}↑${ahead}"
            fi
            
            if [[ $behind -gt 0 ]]; then
                git_status="${git_status}↓${behind}"
            fi
        fi
        
        # Format the output with colors
        echo -e " \033[35m($branch$git_status)\033[0m"
    fi
}

# This line will be moved to the end of the file
bind "set completion-ignore-case on"
shopt -s nocaseglob

# Aliases for efficiency
alias deleteBranch='git branch -D'
alias gitclean='git branch | egrep -v "(master|marcus-experiments|\*)" | xargs git branch -D'
alias fclean='git co . && git clean -df'
alias nb='npm run build'
alias nl='npm run lint -- --fix'
alias ghd='gh dash'

# yt-dlp aliases
alias ytd='yt-dlp --cookies-from-browser vivaldi -P /mnt/stuff/Clips -f "bv*[ext=mp4][height<=1080]+ba[ext=m4a]/b[ext=mp4]/best" --merge-output-format mp4'
alias ytdmax='yt-dlp --cookies-from-browser vivaldi -P /mnt/stuff/Clips -f "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best" --merge-output-format mp4'
alias yta='yt-dlp --cookies-from-browser vivaldi -P ~/Music -f "ba[ext=m4a]/ba/b" --extract-audio --audio-format mp3 --audio-quality 0'

alias ac='aicommits'
alias aca='git add . && aicommits'
alias vim='nvim'
alias vi='nvim'
alias c='clear'
alias sb='swift build'
alias st='swift test'

# Open AI Key 

# Tailscale
alias tsget='sudo tailscale file get ~/Downloads/'
alias tsend='function _tsend() { 
    local source="$1"
    sudo tailscale file cp "$source" galaxy-s22-ultra: && 
    sudo tailscale file cp "$source" iphone-15-pro-max:
}; _tsend'

# Function definitions
function run_tests() {
    local project_path="$1"
    local scheme="$2"
    xcodebuild test -project "$project_path" -scheme "$scheme" -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation),OS=latest'
}

# Which completions would you like to load? (completions can be found in ~/.oh-my-bash/completions/*)
# Custom completions may be added to ~/.oh-my-bash/custom/completions/
# Example format: completions=(ssh git bundler gem pip pip3)
# Add wisely, as too many completions slow down shell startup.
completions=(
  git
  composer
  ssh
)

# Which aliases would you like to load? (aliases can be found in ~/.oh-my-bash/aliases/*)
# Custom aliases may be added to ~/.oh-my-bash/custom/aliases/
# Example format: aliases=(vagrant composer git-avh)
# Add wisely, as too many aliases slow down shell startup.
aliases=(
  general
)

# Which plugins would you like to load? (plugins can be found in ~/.oh-my-bash/plugins/*)
# Custom plugins may be added to ~/.oh-my-bash/custom/plugins/
# Example format: plugins=(rails git textmate ruby lighthouse)
# Add wisely, as too many plugins slow down shell startup.
plugins=(
  git
  sudo
  bashmarks
)

source "$OSH"/oh-my-bash.sh

THEME_SHOW_CLOCK=false

# Set name of the theme to load. Optionally, if you set this to "random"
# it'll load a random theme each time that oh-my-bash is loaded.
OSH_THEME=""

# To disable the uses of "sudo" by oh-my-bash, please set "false" to
# this variable.  The default behavior for the empty value is "true".
OMB_USE_SUDO=true

# If you set OSH_THEME to "random", you can ignore themes you don't like.
# OMB_THEME_RANDOM_IGNORED=("powerbash10k" "wanelo")

# Uncomment the following line to use case-sensitive completion.
# OMB_CASE_SENSITIVE="true"

# Uncomment the following line to use hyphen-insensitive completion. Case
# sensitive completion must be off. _ and - will be interchangeable.
# OMB_HYPHEN_SENSITIVE="false"

# Uncomment the following line to disable bi-weekly auto-update checks.
# DISABLE_AUTO_UPDATE="true"

# Uncomment the following line to change how often to auto-update (in days).
# export UPDATE_OSH_DAYS=13

# Uncomment the following line to disable colors in ls.
# DISABLE_LS_COLORS="true"

# Uncomment the following line to disable auto-setting terminal title.
# DISABLE_AUTO_TITLE="true"

# Uncomment the following line to enable command auto-correction.
# ENABLE_CORRECTION="true"

# Uncomment the following line to display red dots whilst waiting for completion.
# COMPLETION_WAITING_DOTS="true"

# Uncomment the following line if you want to disable marking untracked files
# under VCS as dirty. This makes repository status check for large repositories
# much, much faster.
# DISABLE_UNTRACKED_FILES_DIRTY="true"

# Uncomment the following line if you don't want the repository to be considered dirty
# if there are untracked files.
# SCM_GIT_DISABLE_UNTRACKED_DIRTY="true"

# Uncomment the following line if you want to completely ignore the presence
# of untracked files in the repository.
# SCM_GIT_IGNORE_UNTRACKED="true"

# Uncomment the following line if you want to change the command execution time
# stamp shown in the history command output.  One of the following values can
# be used to specify the timestamp format.
# * 'mm/dd/yyyy'     # mm/dd/yyyy + time
# * 'dd.mm.yyyy'     # dd.mm.yyyy + time
# * 'yyyy-mm-dd'     # yyyy-mm-dd + time
# * '[mm/dd/yyyy]'   # [mm/dd/yyyy] + [time] with colors
# * '[dd.mm.yyyy]'   # [dd.mm.yyyy] + [time] with colors
# * '[yyyy-mm-dd]'   # [yyyy-mm-dd] + [time] with colors
# If not set, the default value is 'yyyy-mm-dd'.
# HIST_STAMPS='yyyy-mm-dd'

# Uncomment the following line if you do not want OMB to overwrite the existing
# aliases by the default OMB aliases defined in lib/*.sh
# OMB_DEFAULT_ALIASES="check"

# Would you like to use another custom folder than $OSH/custom?
# OSH_CUSTOM=/path/to/new-custom-folder

# Custom prompt with git info (must be after Oh My Bash loads)
PS1='\[\033[32m\]\u@\h\[\033[0m\]:\[\033[34m\]\w\[\033[0m\]$(git_prompt)\$ '

# To enable/disable display of Python virtualenv and condaenv
# OMB_PROMPT_SHOW_PYTHON_VENV=true  # enable
# OMB_PROMPT_SHOW_PYTHON_VENV=false # disable

# Which plugins would you like to conditionally load? (plugins can be found in ~/.oh-my-bash/plugins/*)
# Custom plugins may be added to ~/.oh-my-bash/custom/plugins/
# Example format:
#  if [ "$DISPLAY" ] || [ "$SSH" ]; then
#      plugins+=(tmux-autoattach)
#  fi

# User configuration
# export MANPATH="/usr/local/man:$MANPATH"

# You may need to manually set your language environment
# export LANG=en_US.UTF-8

# Preferred editor for local and remote sessions
# if [[ -n $SSH_CONNECTION ]]; then
#   export EDITOR='vim'
# else
#   export EDITOR='mvim'
# fi

# Compilation flags
# export ARCHFLAGS="-arch x86_64"

# ssh
# export SSH_KEY_PATH="~/.ssh/rsa_id"

# Set personal aliases, overriding those provided by oh-my-bash libs,
# plugins, and themes. Aliases can be placed here, though oh-my-bash
# users are encouraged to define aliases within the OSH_CUSTOM folder.
# For a full list of active aliases, run `alias`.
#
# Example aliases
# alias bashconfig="mate ~/.bashrc"
# alias ohmybash="mate ~/.oh-my-bash"
#

# Claude Code
alias cc="CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 ENABLE_BACKGROUND_TASKS=1 ~/.local/bin/claude --dangerously-skip-permissions"
alias ccc="CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 ENABLE_BACKGROUND_TASKS=1 ~/.local/bin/claude --dangerously-skip-permissions --continue"
alias ccu="~/.local/bin/claude update"
alias ccr="CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 ENABLE_BACKGROUND_TASKS=1 ~/.local/bin/claude --dangerously-skip-permissions --resume"

alias pwdc='pwd  < /dev/null |  xclip -selection clipboard'

# SSH tunnel to macOS or macOS and Claude Code
alias macssh='ssh -q -o LogLevel=quiet -L 8082:localhost:8080 marcus@macos.home'
alias macclaude='ssh -q -o LogLevel=quiet -L 8082:localhost:8080 marcus@macos.home -t "claude --dangerously-skip-permissions; bash"'
export PATH="$HOME/bin:$PATH"

# OpenCode AI
alias oc='opencode'
alias occ='opencode -c'

# Ollama

alias comfy-off="docker stop comfyui"
alias comfy-on="docker start comfyui"
