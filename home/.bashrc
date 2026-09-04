[[ $- != *i* ]] && return

if ! pgrep -u "$USER" ssh-agent > /dev/null; then
    eval "$(ssh-agent -s -t 24h)" > /dev/null
fi
if [[ ! "$SSH_AUTH_SOCK" ]]; then
    export SSH_AUTH_SOCK="$(find /tmp -maxdepth 2 -name 'agent.*' -user "$USER" 2>/dev/null | head -1)"
fi
ssh-add ~/.ssh/id_ed25519 2>/dev/null

export OSH="$HOME/.oh-my-bash"
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

alias ls='ls --color=auto'
alias grep='grep --color=auto'

git_prompt() {
    if git rev-parse --git-dir > /dev/null 2>&1; then
        local branch=$(git branch 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/\1/')
        local git_status=""

        if [[ $(git status --porcelain 2> /dev/null) ]]; then
            git_status="${git_status}*"
        fi

        if ! git diff --cached --quiet 2> /dev/null; then
            git_status="${git_status}+"
        fi

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

        echo -e " \033[35m($branch$git_status)\033[0m"
    fi
}

bind "set completion-ignore-case on"
shopt -s nocaseglob

alias deleteBranch='git branch -D'
alias gitclean='git branch | egrep -v "(master|marcus-experiments|\*)" | xargs git branch -D'
alias fclean='git co . && git clean -df'
alias nb='npm run build'
alias nl='npm run lint -- --fix'
alias ghd='gh dash'

alias ytd='yt-dlp --cookies-from-browser vivaldi -P /mnt/nvme8tb/Clips -f "bv*[vcodec^=avc1][height<=1080]+ba[acodec^=mp4a]/bv*[ext=mp4][height<=1080]+ba[ext=m4a]/b[ext=mp4]/best" --merge-output-format mp4 --exec "after_move:clip-to-twitter %(filepath)q"'
alias ytdmax='yt-dlp --cookies-from-browser vivaldi -P /mnt/nvme8tb/Clips -f "bv*[height<=2160]+ba/b[height<=2160]/b" --merge-output-format mkv --exec "after_move:clip-to-twitter %(filepath)q"'
alias yta='yt-dlp --cookies-from-browser vivaldi -P ~/Music -f "ba[ext=m4a]/ba/b" --extract-audio --audio-format mp3 --audio-quality 0'

alias ac='aicommits'
alias aca='git add . && aicommits'
alias vim='nvim'
alias vi='nvim'
alias c='clear'
alias sb='swift build'
alias st='swift test'
alias t='tmux new -A -s main'

alias tsget='tailscale file get --conflict=rename ~/Downloads/'
alias tsend='function _tsend() {
    local source="$1"
    sudo tailscale file cp "$source" galaxy-s22-ultra: &&
    sudo tailscale file cp "$source" iphone-15-pro-max:
}; _tsend'

function run_tests() {
    local project_path="$1"
    local scheme="$2"
    xcodebuild test -project "$project_path" -scheme "$scheme" -destination 'platform=iOS Simulator,name=iPhone SE (3rd generation),OS=latest'
}

completions=(
  git
  composer
  ssh
)

aliases=(
  general
)

plugins=(
  git
  sudo
  bashmarks
)

source "$OSH"/oh-my-bash.sh

THEME_SHOW_CLOCK=false
OSH_THEME=""
OMB_USE_SUDO=true

PS1='\[\033[32m\]\u@\h\[\033[0m\]:\[\033[34m\]\w\[\033[0m\]$(git_prompt)\$ '

alias cc="DISABLE_ERROR_REPORTING=1 DISABLE_FEEDBACK_COMMAND=1 CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1 ENABLE_BACKGROUND_TASKS=1 ~/.local/bin/claude --dangerously-skip-permissions"
alias ccc="DISABLE_ERROR_REPORTING=1 DISABLE_FEEDBACK_COMMAND=1 CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1 ENABLE_BACKGROUND_TASKS=1 ~/.local/bin/claude --dangerously-skip-permissions --continue"
alias ccu="~/.local/bin/claude update"
alias ccr="DISABLE_ERROR_REPORTING=1 DISABLE_FEEDBACK_COMMAND=1 CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1 ENABLE_BACKGROUND_TASKS=1 ~/.local/bin/claude --dangerously-skip-permissions --resume"

alias pwdc='pwd  < /dev/null |  xclip -selection clipboard'

alias macssh='ssh -q -o LogLevel=quiet -L 8082:localhost:8080 marcus@macos.home'
alias macclaude='ssh -q -o LogLevel=quiet -L 8082:localhost:8080 marcus@macos.home -t "claude --dangerously-skip-permissions; bash"'

alias oc='opencode'
alias occ='opencode -c'

alias comfy-off="docker stop comfyui"
alias comfy-on="docker start comfyui"

[[ -f "$HOME/.cargo/env" ]] && . "$HOME/.cargo/env"

rtmux() { ssh -t "marcus@${1:?usage: rtmux <host> [session]}" "tmux new -A -s ${2:-main}"; }

# >>> grok installer >>>
export PATH="$HOME/.grok/bin:$PATH"
[[ -r "$HOME/.grok/completions/bash/grok.bash" ]] && source "$HOME/.grok/completions/bash/grok.bash"
# <<< grok installer <<<

# opencode
export PATH="$HOME/.opencode/bin:$PATH"
export OPENCODE_CONFIG="$HOME/.config/opencode/opencode.local.json"
