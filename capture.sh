#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# capture.sh — run on the SOURCE machine (the MacBook) to refresh every
# manifest in this kit. Safe to re-run any time; it only writes into this
# directory. Nothing here contains secrets.
#
#   ./capture.sh              refresh manifests + dotfiles
#   ./capture.sh --payload    also build the big tarballs (themes, icons,
#                             fonts, COSMIC config, VS Code settings) into
#                             payload/, which is gitignored — copy those to
#                             the new machine by USB or Drive.
# ---------------------------------------------------------------------------
set -uo pipefail
KIT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
M="$KIT/manifests"; D="$KIT/dotfiles"; P="$KIT/payload"
mkdir -p "$M" "$D/autostart" "$D/local-bin" "$P"

say() { printf '  %s\n' "$*"; }
echo "Capturing system state from $(hostname) ..."

# --- package manifests ---------------------------------------------------
apt-mark showmanual 2>/dev/null | sort > "$M/apt-manual.txt";        say "apt:      $(wc -l < "$M/apt-manual.txt") packages"
flatpak list --app --columns=application 2>/dev/null | sort > "$M/flatpak.txt"; say "flatpak:  $(wc -l < "$M/flatpak.txt") apps"

# snaps, split by confinement — classic snaps need a different install flag
snap list 2>/dev/null | tail -n +2 | awk '$0 !~ /(^(core|core18|core20|core22|core24|bare|snapd|gtk-common-themes|gnome-3-28-1804|gnome-42-2204|gnome-46-2404|mesa-2404) )/ {print $1"\t"$NF}' \
  | awk -F'\t' '{split($2,n,","); c=0; for(i in n) if(n[i]=="classic") c=1; print $1"\t"c}' > "$M/snap.txt"
say "snap:     $(wc -l < "$M/snap.txt") apps"

python3 -m pip list --format=freeze 2>/dev/null > "$M/pip-freeze-full.txt"
# Split out only the pip-installed (~/.local) packages. Anything living in
# /usr/lib/python3/dist-packages is apt's and must NOT be reinstalled by pip.
python3 - "$M/pip-user.txt" <<'PY'
import importlib.metadata as md, sys
out = []
for d in md.distributions():
    name = d.metadata["Name"]
    if name and "/.local/lib" in str(getattr(d, "_path", "") or ""):
        out.append(f"{name}=={d.version}")
open(sys.argv[1], "w").write("\n".join(sorted(out, key=str.lower)) + "\n")
PY
say "pip:      $(wc -l < "$M/pip-user.txt") user packages ($(wc -l < "$M/pip-freeze-full.txt") total in env)"

Rscript -e 'cat(paste(rownames(installed.packages(lib.loc=Sys.getenv("R_LIBS_USER", "~/R/site-library"))), collapse="\n"))' 2>/dev/null > "$M/r-packages.txt"
[ -s "$M/r-packages.txt" ] && say "R:        $(wc -l < "$M/r-packages.txt") packages"

# scoped names survive the JSON form; npm/corepack ship with node itself
npm ls -g --depth=0 --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin).get("dependencies", {})
print("\n".join(sorted(k for k in d if k not in ("npm", "corepack"))))' > "$M/npm-global.txt"
say "npm:      $(wc -l < "$M/npm-global.txt") global packages"

code --list-extensions 2>/dev/null | sort > "$M/vscode-extensions.txt"
[ -s "$M/vscode-extensions.txt" ] && say "vscode:   $(wc -l < "$M/vscode-extensions.txt") extensions"

# --- git repos: path <TAB> remote ---------------------------------------
: > "$M/git-repos.txt"
find "$HOME" -maxdepth 3 -name .git -type d -not -path "*/venv/*" -not -path "*/.venv/*" 2>/dev/null |
while read -r g; do
    d="$(dirname "$g")"
    url="$(git -C "$d" remote get-url origin 2>/dev/null)" || continue
    [ -n "$url" ] && printf '%s\t%s\n' "${d#$HOME/}" "$url"
done | sort > "$M/git-repos.txt"
say "repos:    $(wc -l < "$M/git-repos.txt") git checkouts"

# --- dotfiles ------------------------------------------------------------
for f in .bashrc .profile .gitconfig .condarc .xprofile .gtkrc-2.0 .selected_editor; do
    [ -f "$HOME/$f" ] && cp -f "$HOME/$f" "$D/${f#.}"
done
cp -f "$HOME"/.config/autostart/*.desktop "$D/autostart/" 2>/dev/null
# hand-written scripts in ~/.local/bin (skip symlinks into repos and pip shims)
for f in fix-text-scaling.sh mount-gdrive.sh NRL; do
    [ -f "$HOME/.local/bin/$f" ] && [ ! -L "$HOME/.local/bin/$f" ] && cp -f "$HOME/.local/bin/$f" "$D/local-bin/$f"
done
say "dotfiles: $(ls "$D" | wc -l) files + $(ls "$D/autostart" 2>/dev/null | wc -l) autostart entries"

# --- environment notes ---------------------------------------------------
{
    echo "captured: $(date -Is)"
    echo "host:     $(hostname)"
    echo "machine:  $(cat /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null)"
    echo "os:       $(. /etc/os-release; echo "$PRETTY_NAME")"
    echo "kernel:   $(uname -r)"
    echo "desktop:  ${XDG_CURRENT_DESKTOP:-unknown}"
    echo "locale:   $(localectl status 2>/dev/null | awk -F= '/System Locale/{print $2}')"
    echo "keymap:   $(localectl status 2>/dev/null | awk '/X11 Layout/{print $3}')"
    echo "timezone: $(timedatectl show -p Timezone --value 2>/dev/null)"
    echo "groups:   $(id -Gn)"
} > "$M/system-info.txt"

# --- optional big payload ------------------------------------------------
if [ "${1:-}" = "--payload" ]; then
    echo "Building payload tarballs (this takes a few minutes) ..."
    tar -C "$HOME" -czf "$P/themes-icons-fonts.tar.gz" \
        --exclude='*.tar.xz' .themes .icons .local/share/icons .local/share/fonts 2>/dev/null
    tar -C "$HOME" -czf "$P/cosmic-config.tar.gz" .config/cosmic 2>/dev/null
    tar -C "$HOME" -czf "$P/vscode-user.tar.gz" \
        --exclude='workspaceStorage' --exclude='History' .config/Code/User 2>/dev/null
    ls -lh "$P"/*.tar.gz 2>/dev/null | awk '{print "  payload: "$9" ("$5")"}'
fi

echo "Done. Manifests written to $M"
