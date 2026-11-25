#!/usr/bin/env bash
# =====================================================================
#  mpv-iina installer for Linux  (works OFFLINE — thumbfast & uosc are bundled in vendor/)
#    ./install.sh                -> iina_osc + configs
#    ./install.sh --thumbnails   -> + thumbfast (seek previews)
#    ./install.sh --uosc         -> + uosc (menus, file browser)
#    ./install.sh --all          -> everything
#    ./install.sh --all --online -> download the latest versions instead of the bundled ones
#    ./install.sh --all --online --proxy socks5h://127.0.0.1:1080
# =====================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MPV_DIR="${MPV_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/mpv}"
WITH_THUMBS=0; WITH_UOSC=0; ONLINE=0; PROXY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --thumbnails) WITH_THUMBS=1 ;;
    --uosc)       WITH_UOSC=1 ;;
    --all)        WITH_THUMBS=1; WITH_UOSC=1 ;;
    --online)     ONLINE=1 ;;
    --proxy)      shift; PROXY="${1:-}" ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
  shift
done

say()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!! \033[0m %s\n" "$*"; }
die()  { printf "\033[1;31mxx \033[0m %s\n" "$*"; exit 1; }

# download URL1 [URL2 ...] -> $OUT ; tries every mirror, returns 1 if all fail
fetch() {
  local out="$1"; shift
  local args=(-fL --retry 2 --connect-timeout 15 -o "$out")
  [ -n "$PROXY" ] && args+=(-x "$PROXY")
  for url in "$@"; do
    say "  trying $url"
    if curl "${args[@]}" "$url" 2>/dev/null; then return 0; fi
  done
  return 1
}

command -v mpv >/dev/null || warn "mpv is not installed (sudo apt install mpv / sudo pacman -S mpv / sudo dnf install mpv)"

# 1) backup
if [ -d "$MPV_DIR" ] && [ -n "$(ls -A "$MPV_DIR" 2>/dev/null)" ]; then
  BK="${MPV_DIR}.backup-$(date +%Y%m%d-%H%M%S)"
  say "Backing up current config -> $BK"
  cp -a "$MPV_DIR" "$BK" || die "backup failed"
fi
mkdir -p "$MPV_DIR/scripts" "$MPV_DIR/script-opts" "$MPV_DIR/scripts-disabled" "$MPV_DIR/fonts"

# 2) move other OSC scripts out of the way (they would draw a second bar)
for f in osc.lua modernx.lua modernz.lua modernglass.lua mordenx.lua; do
  if [ -e "$MPV_DIR/scripts/$f" ]; then
    warn "Disabling conflicting script: $f -> scripts-disabled/"
    mv "$MPV_DIR/scripts/$f" "$MPV_DIR/scripts-disabled/"
  fi
done

# 3) iina_osc + configs
say "Installing iina_osc.lua and configs"
cp "$HERE/scripts/iina_osc.lua" "$MPV_DIR/scripts/"            || die "copy failed"
cp "$HERE/mpv.conf" "$HERE/input.conf" "$MPV_DIR/"             || die "copy failed"
cp "$HERE/script-opts/iina_osc.conf" "$MPV_DIR/script-opts/"   || die "copy failed"

# 4) thumbfast
if [ "$WITH_THUMBS" = 1 ]; then
  ok=0
  if [ "$ONLINE" = 1 ]; then
    say "Downloading thumbfast"
    fetch "$MPV_DIR/scripts/thumbfast.lua.part" \
      "https://raw.githubusercontent.com/po5/thumbfast/master/thumbfast.lua" \
      "https://cdn.jsdelivr.net/gh/po5/thumbfast@master/thumbfast.lua" \
      && mv "$MPV_DIR/scripts/thumbfast.lua.part" "$MPV_DIR/scripts/thumbfast.lua" && ok=1
    rm -f "$MPV_DIR/scripts/thumbfast.lua.part"
    [ "$ok" = 0 ] && warn "Download failed — using the bundled copy instead"
  fi
  if [ "$ok" = 0 ]; then
    say "Installing bundled thumbfast"
    cp "$HERE/vendor/scripts/thumbfast.lua" "$MPV_DIR/scripts/" && ok=1
  fi
  [ "$ok" = 1 ] || warn "thumbfast was NOT installed (seek thumbnails disabled)"
fi

# 5) uosc (menus only mode)
if [ "$WITH_UOSC" = 1 ]; then
  ok=0
  if [ "$ONLINE" = 1 ] && command -v unzip >/dev/null; then
    say "Downloading uosc"
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    if fetch "$TMP/uosc.zip" "https://github.com/tomasklaen/uosc/releases/latest/download/uosc.zip"; then
      rm -rf "$MPV_DIR/scripts/uosc"
      unzip -qo "$TMP/uosc.zip" -d "$MPV_DIR" && ok=1
    else
      warn "Download failed — using the bundled copy instead"
    fi
  fi
  if [ "$ok" = 0 ]; then
    say "Installing bundled uosc"
    rm -rf "$MPV_DIR/scripts/uosc"
    cp -r "$HERE/vendor/uosc/scripts/uosc" "$MPV_DIR/scripts/" &&
    cp "$HERE"/vendor/uosc/fonts/* "$MPV_DIR/fonts/" && ok=1
  fi
  if [ "$ok" = 1 ]; then
    cp "$HERE/script-opts/uosc.conf" "$MPV_DIR/script-opts/"
  else
    warn "uosc was NOT installed (built-in mpv menus will be used)"
  fi
fi

# 6) fonts & helpers
# fc-match (not "fc-list | grep -q"): with "set -o pipefail", grep -q exits early,
# fc-list gets SIGPIPE and the pipeline reports failure even when Inter IS installed.
if command -v fc-match >/dev/null && ! fc-match -f '%{family}\n' 'Inter' 2>/dev/null | grep -qi '^Inter'; then
  warn "Font 'Inter' not found. Install it for the IINA look:"
  warn "   Debian/Ubuntu: sudo apt install fonts-inter    Arch: sudo pacman -S inter-font    Fedora: sudo dnf install rsms-inter-fonts"
fi
if ! command -v zenity >/dev/null && ! command -v kdialog >/dev/null && [ "$WITH_UOSC" = 0 ]; then
  warn "Install zenity or kdialog (or use --uosc) so the 'Open file' button works."
fi

say "Done! Try:  mpv ~/Videos/some-video.mkv   or just:  mpv"
