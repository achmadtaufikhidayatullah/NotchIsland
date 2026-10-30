# NotchIsland: beri tahu notch saat command terminal yang lama selesai.
# Dimuat dari ~/.zshrc. Ambang bisa diubah: export NOTCH_MIN_SECONDS=60
zmodload zsh/datetime 2>/dev/null

typeset -g _notch_cmd="" _notch_start=0

_notch_preexec() {
  _notch_cmd="$1"
  _notch_start=$EPOCHREALTIME
}

_notch_precmd() {
  local exit_code=$?
  [[ -z "$_notch_cmd" ]] && return
  local cmd="$_notch_cmd"
  _notch_cmd=""
  local -i dur=$(( EPOCHREALTIME - _notch_start ))   # -i memotong ke detik bulat
  (( dur < ${NOTCH_MIN_SECONDS:-30} )) && return
  (( exit_code == 130 )) && return   # dihentikan sendiri dengan Ctrl-C
  # Program interaktif bukan "pekerjaan" yang ditunggu.
  case "${${cmd## #}%% *}" in
    vim|nvim|vi|nano|less|more|man|ssh|top|htop|btop|claude|agy|tmux|zellij|watch|tail|python|python3|node|irb) return ;;
  esac

  local dir="$HOME/Library/Application Support/NotchIsland/terminal"
  mkdir -p "$dir" 2>/dev/null || return
  # Escape JSON minimal; karakter kontrol lain cukup diganti spasi.
  local c=${cmd//\\/\\\\}; c=${c//\"/\\\"}; c=${c//[[:cntrl:]]/ }
  local d=${PWD//\\/\\\\}; d=${d//\"/\\\"}
  local f="$dir/${EPOCHREALTIME/./-}-$$"
  printf '{"command":"%s","exit":%d,"duration":%d,"cwd":"%s","term":"%s","bundle":"%s"}\n' \
    "$c" "$exit_code" "$dur" "$d" "${TERM_PROGRAM:-}" "${__CFBundleIdentifier:-}" > "$f.tmp" 2>/dev/null \
    && mv "$f.tmp" "$f.json"
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _notch_preexec
add-zsh-hook precmd _notch_precmd
