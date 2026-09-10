# Pop!_OS setup kit

Rebuilds this environment on a fresh Pop!_OS 24.04 install.

- **Source machine** — Apple MacBookPro12,1, Intel i5-5257U, Iris 6100, Pop!_OS 24.04, COSMIC
- **Target machine** — Gigabyte H370N-WIFI, Intel i5-8400, **AMD Radeon RX 5700 XT**

Because the target is an AMD desktop and the source is an Intel Mac laptop, the
kit deliberately does **not** carry everything across verbatim. See
[What is deliberately different](#what-is-deliberately-different).

---

## Before you start

Install Pop!_OS 24.04 from the **Intel/AMD ISO** — *not* the NVIDIA one. The
RX 5700 XT uses the open-source `amdgpu` driver that is already in the kernel;
the NVIDIA ISO would install a proprietary driver the card cannot use.

Create the user account as `martinstevenson` so every path in the manifests
(`/home/martinstevenson/...`) lines up.

## Running it

```bash
git clone https://github.com/mhs795/popos-setup.git ~/popos-setup
cd ~/popos-setup
./setup.sh --dry-run        # see what it would do, change nothing
./setup.sh                  # do it
```

It takes an hour or two, mostly compiling R packages. Everything is logged to
`setup-<timestamp>.log`, and no single failure aborts the run — failures are
collected and printed at the end.

Every phase is **idempotent**. If something fails, fix it and re-run either the
whole thing or just that phase:

```bash
./setup.sh --list           # preflight repos apt gpu flatpak snap python r
                            # node vscode dotfiles clone desktop finish
./setup.sh r node           # re-run only those two
```

| Flag | Effect |
|---|---|
| `--dry-run` | print what would happen, change nothing |
| `--hardware-too` | also install the MacBook/System76-specific packages (don't, on the desktop) |
| `--hidpi` | keep the MacBook's 2× Retina scaling in `.xprofile` instead of resetting it to 1× |

## The phases

| Phase | What it does |
|---|---|
| `preflight` | sudo keepalive, base tooling, user groups, `en_AU.UTF-8`, `Australia/Sydney`, `au` keymap |
| `repos` | Brave, Chrome, Spotify, VS Code, CRAN, NordVPN, GitHub CLI apt sources + keys |
| `apt` | the 208 manually-installed packages, minus the stale and hardware-specific ones |
| `gpu` | AMD stack: Mesa/RADV Vulkan, VA-API, `amdgpu` DDX, i386 multiarch, CoreCtrl, radeontop |
| `flatpak` | flathub + cosmic remotes, then 20 apps |
| `snap` | 10 snaps, classic confinement where needed (android-studio, rstudio) |
| `python` | 65 pip packages into `~/.local` (`--break-system-packages`, same as this box) |
| `r` | 79 CRAN packages into `~/R/site-library` |
| `node` | global npm packages + the Claude Code installer |
| `vscode` | 12 extensions |
| `dotfiles` | `.bashrc`, `.profile`, `.gitconfig`, `.condarc`, `.xprofile`, autostart entries, hand-written `~/.local/bin` scripts |
| `clone` | all 18 git checkouts, per-project venvs, `PRICES`/`CAPITA`/`HANK` launcher symlinks |
| `desktop` | themes, icons, fonts, COSMIC and VS Code settings — **needs `payload/`, see below** |
| `finish` | failure summary + the manual checklist |

Existing dotfiles are never clobbered — each is copied to `<name>.bak-<timestamp>` first.

## The payload

Themes, icon themes, fonts and desktop config total ~1.5 GB, which is too big
for git. Build them on the **source** machine and carry them over by USB or
Drive:

```bash
./capture.sh --payload      # writes payload/*.tar.gz (gitignored)
```

Then drop those `.tar.gz` files into `payload/` on the new machine before
running the `desktop` phase. Without them, that phase just skips with a note —
everything else still works.

## Keeping the kit current

Re-run `./capture.sh` on the source machine any time you install something new.
It rewrites every manifest from the live system, so the kit never drifts.

## What is deliberately different

Skipped by default (listed with reasons in `manifests/apt-hardware-specific.txt`):

- `nvidia-driver-570-open` — **wrong card.** The 5700 XT uses `amdgpu` + Mesa,
  installed by the `gpu` phase. Nothing proprietary to install.
- `macfanctld` — Apple fan control, and the `mactel-support` PPA behind it
- `system76-{dkms,io-dkms,acpi-dkms}` — System76 hardware only
- `tlp`, `tlp-rdw` — laptop power management
- `amd-ppt-bin` — Ryzen power tuning; the target CPU is an Intel i5-8400

Dropped as dead weight (`manifests/apt-stale.txt`) — 15 leftovers from an old
jammy→noble upgrade (`libicu70`, `python3.10`, `libprocps8`, …) that noble no
longer ships and nothing needs.

Rewritten:

- **`.xprofile` scaling.** The MacBook's Retina panel wants `GDK_SCALE=2` /
  `QT_SCALE_FACTOR=2`. On a normal desktop monitor that makes every Qt and GTK
  app enormous, so the `dotfiles` phase resets both to `1`. Pass `--hidpi` to
  keep 2×.
- **`~/.local/bin/fix-text-scaling.sh`** still sets 1.75× text scaling under
  KDE (also a Retina value). It does nothing under COSMIC. Edit it if you end
  up using the KDE session on the desktop.

## What the script cannot do

Credentials and data are deliberately not in this repo:

1. `gh auth login`, then `./setup.sh clone`
2. `rclone config` — re-authorise Drive, **name the remote `drive`** (that is
   what `mount-gdrive.sh` expects). While you are there, set up your own Google
   API `client_id`; the shared rclone one is being retired during 2026 — steps
   are in the comment block at the bottom of `~/.local/bin/mount-gdrive.sh`.
3. `nordvpn login`
4. Sign in to Brave/Chrome, Spotify, Discord, VS Code, Claude, Steam
5. Copy the data that lives in no git repo:
   `~/models/nves_optimization_model` (553 MB), `~/models/tech_models` (2.6 MB),
   `~/models/archive_v9_full_emissions` (113 MB), plus `~/Documents`,
   `~/Pictures`, `~/Music`, `~/.ssh`
6. `rnaturalearthhires` is not on CRAN. After the `r` phase:
   ```r
   install.packages("rnaturalearthhires",
                    repos = "https://ropensci.r-universe.dev", type = "source")
   ```
7. Log out and back in — group membership and `PATH` need a fresh session.
