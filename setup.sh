#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup.sh — rebuild Martin's Pop!_OS environment on a fresh install.
#
# Run it on the NEW machine after a clean Pop!_OS 24.04 install, as the normal
# user (NOT with sudo — it calls sudo itself where needed).
#
#   ./setup.sh                 run every phase, in order
#   ./setup.sh apt flatpak     run only the named phases
#   ./setup.sh --list          show the phases and stop
#   ./setup.sh --dry-run       print what would happen, change nothing
#   ./setup.sh --hardware-too  also install the MacBook/System76-specific
#                              packages that are skipped by default
#   ./setup.sh --hidpi         keep the MacBook's 2x Retina scaling in
#                              .xprofile (default: rewritten to 1x, which is
#                              what a normal desktop monitor wants)
#
# Every phase is idempotent: re-running is safe and skips work already done.
# A failing package never aborts the run; failures are collected and printed
# at the end.
# ---------------------------------------------------------------------------
set -uo pipefail

KIT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
M="$KIT/manifests"; D="$KIT/dotfiles"; P="$KIT/payload"
LOG="$KIT/setup-$(date +%Y%m%d-%H%M%S).log"
DRY=0; HARDWARE=0; HIDPI=0
FAILED=()

PHASES=(preflight repos apt gpu flatpak snap python r node vscode dotfiles clone desktop finish)

# --- output helpers -------------------------------------------------------
c_hdr()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
c_ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
c_skip() { printf '    \033[90m·\033[0m %s\n' "$*"; }
c_warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }
c_err()  { printf '    \033[31m✗\033[0m %s\n' "$*"; FAILED+=("$*"); }

run() {   # run a command, or just show it under --dry-run
    if [ "$DRY" = 1 ]; then printf '    \033[90m[dry-run]\033[0m %s\n' "$*"; return 0; fi
    "$@" >>"$LOG" 2>&1
}

have() { command -v "$1" >/dev/null 2>&1; }

# strip comments/blanks from a manifest
list() { [ -f "$1" ] && grep -vE '^\s*(#|$)' "$1"; }

# --- argument parsing -----------------------------------------------------
WANTED=()
while [ $# -gt 0 ]; do
    case "$1" in
        --list)         printf '%s\n' "${PHASES[@]}"; exit 0 ;;
        --dry-run)      DRY=1; shift ;;
        --hardware-too) HARDWARE=1; shift ;;
        --hidpi)        HIDPI=1; shift ;;
        -h|--help)      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)             echo "unknown option: $1" >&2; exit 2 ;;
        *)              WANTED+=("$1"); shift ;;
    esac
done
[ ${#WANTED[@]} -eq 0 ] && WANTED=("${PHASES[@]}")

want() { local p; for p in "${WANTED[@]}"; do [ "$p" = "$1" ] && return 0; done; return 1; }

[ "$(id -u)" = 0 ] && { echo "Run as your normal user, not root — setup.sh calls sudo itself."; exit 1; }

echo "Pop!_OS setup kit — log: $LOG"
[ "$DRY" = 1 ] && echo "(dry run — nothing will be changed)"


# ===========================================================================
# preflight — sudo, base tooling, groups, locale, timezone
# ===========================================================================
if want preflight; then
    c_hdr "Preflight"
    if [ "$DRY" = 0 ]; then
        sudo -v || { echo "sudo required"; exit 1; }
        # keep the sudo timestamp alive for the whole run
        while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
        SUDO_KEEPALIVE=$!
        trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null' EXIT
    fi

    run sudo apt-get update
    run sudo apt-get install -y curl wget gpg ca-certificates apt-transport-https software-properties-common git
    c_ok "base tooling"

    for g in sudo adm input lpadmin; do
        if id -nG "$USER" | tr ' ' '\n' | grep -qx "$g"; then c_skip "already in group $g"
        else run sudo usermod -aG "$g" "$USER" && c_ok "added to group $g (log out to take effect)"; fi
    done

    tz="$(grep '^timezone:' "$M/system-info.txt" | awk '{print $2}')"
    [ -n "$tz" ] && { run sudo timedatectl set-timezone "$tz"; c_ok "timezone $tz"; }
    loc="$(grep '^locale:' "$M/system-info.txt" | awk '{print $2}')"
    if [ -n "$loc" ]; then
        run sudo locale-gen "$loc"
        run sudo update-locale "LANG=$loc"
        c_ok "locale $loc"
    fi
    km="$(grep '^keymap:' "$M/system-info.txt" | awk '{print $2}')"
    [ -n "$km" ] && { run sudo localectl set-x11-keymap "$km" pc105; c_ok "keyboard layout $km"; }
fi


# ===========================================================================
# repos — third-party apt sources
# ===========================================================================
if want repos; then
    c_hdr "Third-party apt repositories"

    add_repo() {   # name  keyring-url  repo-line  [sources-file]
        local name="$1" keyurl="$2" line="$3" file="${4:-$1}"
        if [ -f "/etc/apt/sources.list.d/$file.list" ] || [ -f "/etc/apt/sources.list.d/$file.sources" ]; then
            c_skip "$name already configured"; return 0
        fi
        if [ -n "$keyurl" ]; then
            if [ "$DRY" = 1 ]; then printf '    \033[90m[dry-run]\033[0m fetch key %s\n' "$keyurl"
            else curl -fsSL "$keyurl" | sudo gpg --dearmor -o "/usr/share/keyrings/$name-archive-keyring.gpg" 2>>"$LOG" \
                    || { c_err "$name: key fetch failed"; return 1; }
            fi
        fi
        if [ "$DRY" = 1 ]; then printf '    \033[90m[dry-run]\033[0m add %s\n' "$line"
        else echo "$line" | sudo tee "/etc/apt/sources.list.d/$file.list" >/dev/null; fi
        c_ok "$name"
    }

    add_repo brave-browser https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
        "deb [arch=amd64 signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main"

    add_repo google-chrome https://dl.google.com/linux/linux_signing_key.pub \
        "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome-archive-keyring.gpg] https://dl.google.com/linux/chrome/deb/ stable main"

    add_repo spotify https://download.spotify.com/debian/pubkey_C85668DF69375001.gpg \
        "deb [signed-by=/usr/share/keyrings/spotify-archive-keyring.gpg] https://repository.spotify.com stable non-free"

    add_repo microsoft https://packages.microsoft.com/keys/microsoft.asc \
        "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-archive-keyring.gpg] https://packages.microsoft.com/repos/code stable main" vscode

    add_repo cran https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc \
        "deb [signed-by=/usr/share/keyrings/cran-archive-keyring.gpg] https://cloud.r-project.org/bin/linux/ubuntu noble-cran40/" cran-r

    # NordVPN ships its own installer that sets up the repo and the nordvpn group
    if [ -f /etc/apt/sources.list.d/nordvpn.list ] || have nordvpn; then
        c_skip "nordvpn already configured"
    elif [ "$DRY" = 1 ]; then printf '    \033[90m[dry-run]\033[0m nordvpn installer\n'
    else
        sh <(curl -fsSL https://downloads.nordcdn.com/apps/linux/install.sh) -n >>"$LOG" 2>&1 \
            && c_ok "nordvpn" || c_err "nordvpn installer failed"
        sudo usermod -aG nordvpn "$USER" 2>>"$LOG"
    fi

    # GitHub CLI
    if have gh || [ -f /etc/apt/sources.list.d/github-cli.list ]; then c_skip "gh already configured"
    else
        add_repo githubcli https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            "deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" github-cli
    fi

    run sudo apt-get update
    c_ok "apt index refreshed"
fi


# ===========================================================================
# apt — the manually-installed package set
# ===========================================================================
if want apt; then
    c_hdr "APT packages"

    mapfile -t wanted < <(list "$M/apt-manual.txt")
    mapfile -t stale  < <(list "$M/apt-stale.txt")
    mapfile -t hw     < <(list "$M/apt-hardware-specific.txt")

    skip_set=" ${stale[*]} "
    [ "$HARDWARE" = 0 ] && skip_set="$skip_set ${hw[*]} "

    install=(); dropped=()
    for p in "${wanted[@]}"; do
        case "$skip_set" in *" $p "*) dropped+=("$p"); continue ;; esac
        install+=("$p")
    done
    [ ${#dropped[@]} -gt 0 ] && c_skip "skipped ${#dropped[@]} stale/hardware-specific: ${dropped[*]}"

    # keep only what the archive actually offers on this machine
    available=(); missing=()
    for p in "${install[@]}"; do
        if apt-cache show "$p" >/dev/null 2>&1; then available+=("$p"); else missing+=("$p"); fi
    done
    [ ${#missing[@]} -gt 0 ] && c_warn "not in any configured repo, skipping: ${missing[*]}"

    echo "    installing ${#available[@]} packages (this is the long part)..."
    if [ "$DRY" = 1 ]; then
        printf '    \033[90m[dry-run]\033[0m apt-get install -y %s\n' "${available[*]:0:8} ..."
    elif sudo apt-get install -y "${available[@]}" >>"$LOG" 2>&1; then
        c_ok "all ${#available[@]} packages installed"
    else
        # one bad package shouldn't sink the batch — retry individually
        c_warn "batch install hit an error, retrying package by package"
        for p in "${available[@]}"; do
            dpkg -s "$p" >/dev/null 2>&1 && continue
            sudo apt-get install -y "$p" >>"$LOG" 2>&1 || c_err "apt: $p"
        done
        c_ok "individual retry finished"
    fi

    if [ "$HARDWARE" = 0 ]; then
        c_skip "NVIDIA driver deliberately not installed — the gpu phase handles the RX 5700 XT"
    fi
fi


# ===========================================================================
# gpu — AMD Radeon RX 5700 XT userspace (Mesa/RADV, VA-API, 32-bit)
# ===========================================================================
if want gpu; then
    c_hdr "AMD GPU stack (RX 5700 XT)"

    if lspci 2>/dev/null | grep -qiE 'vga|3d' && ! lspci 2>/dev/null | grep -qiE 'vga|3d.*(amd|ati|radeon)'; then
        c_warn "no AMD card detected here — installing the AMD stack anyway (this is the target's card)"
    fi

    if dpkg --print-foreign-architectures | grep -qx i386; then
        c_skip "i386 multiarch already enabled"
    else
        run sudo dpkg --add-architecture i386
        run sudo apt-get update
        c_ok "i386 multiarch enabled (needed by Steam and most of Lutris)"
    fi

    mapfile -t gpupkgs < <(list "$M/apt-gpu-amd.txt")
    avail=(); miss=()
    for p in "${gpupkgs[@]}"; do
        if apt-cache show "$p" >/dev/null 2>&1; then avail+=("$p"); else miss+=("$p"); fi
    done
    [ ${#miss[@]} -gt 0 ] && c_warn "not available, skipping: ${miss[*]}"

    if [ "$DRY" = 1 ]; then
        printf '    \033[90m[dry-run]\033[0m apt-get install -y %s\n' "${avail[*]}"
    elif sudo apt-get install -y "${avail[@]}" >>"$LOG" 2>&1; then
        c_ok "${#avail[@]} GPU packages installed"
    else
        c_warn "batch failed, retrying package by package"
        for p in "${avail[@]}"; do
            dpkg -s "${p%%:*}" >/dev/null 2>&1 && continue
            sudo apt-get install -y "$p" >>"$LOG" 2>&1 || c_err "gpu: $p"
        done
    fi

    # amdgpu wants no proprietary blob; just confirm the kernel picked it up
    if [ "$DRY" = 0 ]; then
        if lsmod 2>/dev/null | grep -q '^amdgpu'; then c_ok "amdgpu kernel module loaded"
        else c_skip "amdgpu module not loaded (expected — this is not the AMD machine)"; fi
        have vulkaninfo && { vulkaninfo --summary >>"$LOG" 2>&1 && c_ok "Vulkan reports a working driver" || c_warn "vulkaninfo found no Vulkan device (normal on the MacBook)"; }
    fi
fi


# ===========================================================================
# flatpak
# ===========================================================================
if want flatpak; then
    c_hdr "Flatpak apps"
    if ! have flatpak; then run sudo apt-get install -y flatpak; fi
    run flatpak remote-add --if-not-exists --user flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    run flatpak remote-add --if-not-exists --user cosmic https://apt.pop-os.org/cosmic/cosmic.flatpakrepo
    c_ok "remotes: flathub, cosmic"

    while read -r app; do
        [ -z "$app" ] && continue
        if flatpak info "$app" >/dev/null 2>&1; then c_skip "$app"; continue; fi
        if [ "$DRY" = 1 ]; then printf '    \033[90m[dry-run]\033[0m flatpak install %s\n' "$app"; continue; fi
        flatpak install -y --user flathub "$app" >>"$LOG" 2>&1 && c_ok "$app" || c_err "flatpak: $app"
    done < <(list "$M/flatpak.txt")
fi


# ===========================================================================
# snap
# ===========================================================================
if want snap; then
    c_hdr "Snap packages"
    if ! have snap; then run sudo apt-get install -y snapd; fi
    while IFS=$'\t' read -r name classic; do
        [ -z "$name" ] && continue
        if snap list "$name" >/dev/null 2>&1; then c_skip "$name"; continue; fi
        flags=(); [ "$classic" = 1 ] && flags=(--classic)
        if [ "$DRY" = 1 ]; then printf '    \033[90m[dry-run]\033[0m snap install %s %s\n' "${flags[*]}" "$name"; continue; fi
        sudo snap install "${flags[@]}" "$name" >>"$LOG" 2>&1 && c_ok "$name${classic:+ (classic)}" || c_err "snap: $name"
    done < <(list "$M/snap.txt")
fi


# ===========================================================================
# python — user-level pip packages
# ===========================================================================
if want python; then
    c_hdr "Python packages (user site)"
    # noble's python is externally managed; --break-system-packages is what
    # this machine already does, and it only ever writes to ~/.local
    PIPFLAGS=(--user --break-system-packages --upgrade)
    if [ "$DRY" = 1 ]; then
        printf '    \033[90m[dry-run]\033[0m pip install %s -r %s\n' "${PIPFLAGS[*]}" "$M/pip-user.txt"
    elif python3 -m pip install "${PIPFLAGS[@]}" -r "$M/pip-user.txt" >>"$LOG" 2>&1; then
        c_ok "$(wc -l < "$M/pip-user.txt") packages installed"
    else
        c_warn "bulk pip install failed, retrying package by package"
        while read -r spec; do
            [ -z "$spec" ] && continue
            python3 -m pip install "${PIPFLAGS[@]}" "$spec" >>"$LOG" 2>&1 || c_err "pip: $spec"
        done < <(list "$M/pip-user.txt")
        c_ok "individual retry finished"
    fi
fi


# ===========================================================================
# r — CRAN packages into ~/R/site-library
# ===========================================================================
if want r; then
    c_hdr "R packages"
    if ! have Rscript; then c_err "R not installed — run the apt phase first"
    else
        RLIB="$HOME/R/site-library"
        mkdir -p "$RLIB"
        if [ "$DRY" = 1 ]; then
            printf '    \033[90m[dry-run]\033[0m install %s CRAN packages into %s\n' "$(wc -l < "$M/r-packages.txt")" "$RLIB"
        else
            echo "    installing $(wc -l < "$M/r-packages.txt") CRAN packages (compiles from source; slow)..."
            Rscript -e "
              lib <- path.expand('$RLIB')
              .libPaths(c(lib, .libPaths()))
              want <- readLines('$M/r-packages.txt')
              want <- want[nzchar(want)]
              have <- rownames(installed.packages())
              todo <- setdiff(want, have)
              if (length(todo)) install.packages(todo, lib = lib, repos = 'https://cloud.r-project.org', Ncpus = max(1, parallel::detectCores() - 1))
              missing <- setdiff(want, rownames(installed.packages()))
              if (length(missing)) cat('STILL MISSING:', paste(missing, collapse = ', '), '\n')
            " >>"$LOG" 2>&1
            if grep -q "STILL MISSING" "$LOG"; then
                c_warn "$(grep 'STILL MISSING' "$LOG" | tail -1)"
                c_warn "rnaturalearthhires is not on CRAN — install it from r-universe (see README)"
            else
                c_ok "all CRAN packages installed"
            fi
        fi
    fi
fi


# ===========================================================================
# node — global npm packages
# ===========================================================================
if want node; then
    c_hdr "Global npm packages"
    if ! have npm; then c_err "npm not installed — run the apt phase first"
    else
        while read -r pkg; do
            [ -z "$pkg" ] && continue
            if [ "$DRY" = 1 ]; then printf '    \033[90m[dry-run]\033[0m npm -g install %s\n' "$pkg"; continue; fi
            sudo npm install -g "$pkg" >>"$LOG" 2>&1 && c_ok "$pkg" || c_err "npm: $pkg"
        done < <(list "$M/npm-global.txt")
    fi
    # Claude Code installs itself outside npm
    if have claude; then c_skip "claude code already installed"
    elif [ "$DRY" = 1 ]; then printf '    \033[90m[dry-run]\033[0m install claude code\n'
    else
        curl -fsSL https://claude.ai/install.sh | bash >>"$LOG" 2>&1 && c_ok "claude code" || c_err "claude code installer"
    fi
fi


# ===========================================================================
# vscode — extensions
# ===========================================================================
if want vscode; then
    c_hdr "VS Code extensions"
    if ! have code; then c_err "code not installed — run the apt phase first"
    else
        installed="$(code --list-extensions 2>/dev/null)"
        while read -r ext; do
            [ -z "$ext" ] && continue
            if grep -qix "$ext" <<<"$installed"; then c_skip "$ext"; continue; fi
            if [ "$DRY" = 1 ]; then printf '    \033[90m[dry-run]\033[0m code --install-extension %s\n' "$ext"; continue; fi
            code --install-extension "$ext" >>"$LOG" 2>&1 && c_ok "$ext" || c_err "vscode: $ext"
        done < <(list "$M/vscode-extensions.txt")
    fi
fi


# ===========================================================================
# dotfiles — shell, git, autostart, hand-written scripts
# ===========================================================================
if want dotfiles; then
    c_hdr "Dotfiles"
    stamp="$(date +%Y%m%d-%H%M%S)"

    put() {   # put  source-in-kit  dest-in-home
        local src="$D/$1" dst="$HOME/$2"
        [ -f "$src" ] || { c_skip "$2 (not captured)"; return; }
        if [ -f "$dst" ] && cmp -s "$src" "$dst"; then c_skip "$2 (identical)"; return; fi
        if [ "$DRY" = 1 ]; then printf '    \033[90m[dry-run]\033[0m install %s\n' "$2"; return; fi
        [ -f "$dst" ] && cp -a "$dst" "$dst.bak-$stamp"    # never clobber an existing file
        mkdir -p "$(dirname "$dst")"
        cp -f "$src" "$dst"
        c_ok "$2$([ -f "$dst.bak-$stamp" ] && echo " (old one saved as $(basename "$dst").bak-$stamp)")"
    }

    put bashrc          .bashrc
    put profile         .profile
    put gitconfig       .gitconfig
    put condarc         .condarc
    put xprofile        .xprofile
    # The captured .xprofile carries the MacBook's 2x Retina scaling. On a
    # normal desktop monitor that makes every Qt/GTK app enormous, so unless
    # --hidpi was passed, rewrite the scale factors down to 1x.
    if [ "$HIDPI" = 0 ] && [ "$DRY" = 0 ] && [ -f "$HOME/.xprofile" ]; then
        sed -i -e 's/^export GDK_SCALE=.*/export GDK_SCALE=1/' \
               -e 's/^export QT_SCALE_FACTOR=.*/export QT_SCALE_FACTOR=1/' "$HOME/.xprofile"
        c_ok ".xprofile scaling set to 1x for a desktop monitor (--hidpi keeps 2x)"
    fi
    put gtkrc-2.0       .gtkrc-2.0
    put selected_editor .selected_editor

    mkdir -p "$HOME/.local/bin" "$HOME/.config/autostart"
    for f in "$D"/local-bin/*; do
        [ -f "$f" ] || continue
        b="$(basename "$f")"
        if [ "$DRY" = 1 ]; then printf '    \033[90m[dry-run]\033[0m ~/.local/bin/%s\n' "$b"; continue; fi
        cp -f "$f" "$HOME/.local/bin/$b" && chmod +x "$HOME/.local/bin/$b" && c_ok ".local/bin/$b"
    done
    for f in "$D"/autostart/*.desktop; do
        [ -f "$f" ] || continue
        b="$(basename "$f")"
        if [ "$DRY" = 1 ]; then printf '    \033[90m[dry-run]\033[0m autostart/%s\n' "$b"; continue; fi
        cp -f "$f" "$HOME/.config/autostart/$b" && c_ok "autostart/$b"
    done
fi


# ===========================================================================
# clone — git checkouts + per-project venvs
# ===========================================================================
if want clone; then
    c_hdr "Git repositories"
    if have gh && ! gh auth status >/dev/null 2>&1; then
        c_warn "not signed in to GitHub — run 'gh auth login' then re-run: ./setup.sh clone"
    fi

    while IFS=$'\t' read -r rel url; do
        [ -z "$rel" ] && continue
        dst="$HOME/$rel"
        if [ -d "$dst/.git" ]; then c_skip "$rel"; continue; fi
        if [ "$DRY" = 1 ]; then printf '    \033[90m[dry-run]\033[0m clone %s -> ~/%s\n' "$url" "$rel"; continue; fi
        mkdir -p "$(dirname "$dst")"
        git clone "$url" "$dst" >>"$LOG" 2>&1 && c_ok "$rel" || c_err "clone: $rel ($url)"
    done < <(list "$M/git-repos.txt")

    # projects that carry their own requirements get a venv, matching this box
    c_hdr "Project virtualenvs"
    for rel in models/super_microsim models/CGE models/sgm_abm models/gas_market_model \
               models/hank_au models/capita-py sandwich_machine; do
        d="$HOME/$rel"
        [ -d "$d" ] || { c_skip "$rel (not cloned)"; continue; }
        # hank_au and capita-py use .venv; the rest use venv
        vd="$d/venv"; case "$rel" in models/hank_au|models/capita-py) vd="$d/.venv" ;; esac
        if [ -d "$vd" ]; then c_skip "$rel venv"; continue; fi
        if [ "$DRY" = 1 ]; then printf '    \033[90m[dry-run]\033[0m venv for %s\n' "$rel"; continue; fi
        python3 -m venv "$vd" >>"$LOG" 2>&1 || { c_err "venv: $rel"; continue; }
        req=""
        for cand in requirements.txt requirements-dev.txt; do
            [ -f "$d/$cand" ] && { req="$d/$cand"; break; }
        done
        if [ -n "$req" ]; then
            "$vd/bin/pip" install -q -r "$req" >>"$LOG" 2>&1 || c_warn "$rel: some requirements failed (see log)"
        elif [ -f "$d/pyproject.toml" ]; then
            "$vd/bin/pip" install -q -e "$d" >>"$LOG" 2>&1 || c_warn "$rel: editable install failed (see log)"
        fi
        c_ok "$rel venv"
    done

    # ~/.local/bin symlinks that put the model launchers on PATH
    c_hdr "Launcher symlinks"
    link() {   # link  target-under-home  name...
        local tgt="$HOME/$1"; shift
        [ -e "$tgt" ] || { c_skip "$* (target missing)"; return; }
        for n in "$@"; do
            if [ "$DRY" = 1 ]; then printf '    \033[90m[dry-run]\033[0m ln -s %s ~/.local/bin/%s\n' "$tgt" "$n"; continue; fi
            ln -sfn "$tgt" "$HOME/.local/bin/$n" && c_ok "$n"
        done
    }
    link models/au_fuel_prices/PRICES PRICES prices
    link models/capita-py/CAPITA      CAPITA capita
    link models/hank_au/bin/hank      HANK   hank
fi


# ===========================================================================
# desktop — themes, icons, fonts, COSMIC + VS Code settings from payload/
# ===========================================================================
if want desktop; then
    c_hdr "Desktop look & feel"
    restore() {   # restore  tarball  description
        local t="$P/$1"
        if [ ! -f "$t" ]; then c_skip "$2 — $1 not in payload/ (see README)"; return; fi
        if [ "$DRY" = 1 ]; then printf '    \033[90m[dry-run]\033[0m untar %s into ~\n' "$1"; return; fi
        tar -C "$HOME" -xzf "$t" >>"$LOG" 2>&1 && c_ok "$2" || c_err "restore: $1"
    }
    restore themes-icons-fonts.tar.gz "GTK themes, icon themes, cursors, fonts"
    restore cosmic-config.tar.gz      "COSMIC desktop settings"
    restore vscode-user.tar.gz        "VS Code user settings and snippets"

    if [ "$DRY" = 0 ] && have fc-cache; then fc-cache -f >>"$LOG" 2>&1; c_ok "font cache rebuilt"; fi

    # text scaling: the autostart script sets this per desktop session
    if [ "$DRY" = 0 ] && have gsettings; then
        gsettings set org.gnome.desktop.interface text-scaling-factor 1.0 2>>"$LOG" && c_ok "text scaling reset to 1.0"
    fi
fi


# ===========================================================================
# finish — what the script cannot do for you
# ===========================================================================
if want finish; then
    c_hdr "Finished"
    if [ ${#FAILED[@]} -gt 0 ]; then
        printf '\n\033[31m%d item(s) failed:\033[0m\n' "${#FAILED[@]}"
        printf '  - %s\n' "${FAILED[@]}"
        printf '  full detail in %s\n' "$LOG"
    else
        printf '\n\033[32mNo failures.\033[0m\n'
    fi

    cat <<'MANUAL'

Still to do by hand — these need credentials or data that is deliberately
NOT in this kit:

  1. gh auth login                  GitHub sign-in (then: ./setup.sh clone)
  2. rclone config                  re-authorise the Google Drive remote
                                    (name it "drive" — mount-gdrive.sh expects that)
     ...and set up your OWN Google API client_id while you are there: the
     shared rclone client is being retired during 2026. Steps are in the
     comment block at the bottom of ~/.local/bin/mount-gdrive.sh
  3. nordvpn login                  VPN account
  4. Sign in to: Brave/Chrome, Spotify, Discord, VS Code, Claude, Steam
  5. Copy across the data that is not in any git repo:
       ~/models/nves_optimization_model   (553M)
       ~/models/tech_models               (2.6M)
       ~/models/archive_v9_full_emissions (113M)
       ~/Documents, ~/Pictures, ~/Music, ~/.ssh
  6. GPU: the RX 5700 XT needs NO proprietary driver — amdgpu + Mesa are
     already in the kernel and the "gpu" phase added Vulkan/VA-API/32-bit.
     Install Pop!_OS from the Intel/AMD ISO, not the NVIDIA one. Check with:
       vulkaninfo --summary   |   glxinfo -B   |   radeontop
  7. Log out and back in — group changes and PATH need a fresh session

MANUAL
fi
