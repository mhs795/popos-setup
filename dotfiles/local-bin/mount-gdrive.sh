#!/usr/bin/env bash
# Mount Google Drive through GNOME Online Accounts (gvfs) and point ~/GoogleDrive at "My Drive".
# Started at login by ~/.config/autostart/gdrive-gnome.desktop. Keeps running and remounts if the mount drops.
#
#   GDRIVE_ACCOUNT   Google account to mount (default: the first Google account in Online Accounts)
#   GDRIVE_LINK      where the link goes (default: ~/GoogleDrive)
#   GDRIVE_CHECK     seconds between checks (default: 60)
#
# Note: on this mount, `ls` shows Drive file IDs; open files by name, and list names with
#   gio list -a standard::display-name ~/GoogleDrive/<folder>
set -u
LINK="${GDRIVE_LINK:-$HOME/GoogleDrive}"
CHECK="${GDRIVE_CHECK:-60}"
LOG="$HOME/.cache/gdrive-mount.log"
mkdir -p "$(dirname "$LOG")"
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

account() {
  [ -n "${GDRIVE_ACCOUNT:-}" ] && { echo "$GDRIVE_ACCOUNT"; return; }
  gdbus call --session --dest org.gnome.OnlineAccounts --object-path /org/gnome/OnlineAccounts \
    --method org.freedesktop.DBus.ObjectManager.GetManagedObjects 2>/dev/null |
    grep -oE "'ProviderType': <'google'>[^}]*'Identity': <'[^']+'>" | grep -oE "'Identity': <'[^']+'>" |
    head -1 | sed -E "s/.*<'([^']+)'>/\1/"
}

target() {  # FUSE path of My Drive for an account like name@gmail.com
  local user="${1%@*}" host="${1#*@}"
  echo "/run/user/$(id -u)/gvfs/google-drive:host=$host,user=$user/My Drive"
}

mount_once() {
  local acct="$1" t; t="$(target "$acct")"
  [ -d "$t" ] && return 0
  gio mount "google-drive://$acct/" >> "$LOG" 2>&1
  for _ in $(seq 1 30); do [ -d "$t" ] && return 0; sleep 2; done
  return 1
}

link() {
  local t="$1"
  if [ -L "$LINK" ]; then [ "$(readlink "$LINK")" = "$t" ] || ln -sfn "$t" "$LINK"
  elif [ -e "$LINK" ]; then
    if [ -d "$LINK" ] && [ -z "$(ls -A "$LINK" 2>/dev/null)" ] && ! mountpoint -q "$LINK"; then
      rmdir "$LINK" && ln -s "$t" "$LINK"
    else log "not linking: $LINK exists and isn't an empty folder"; return 1; fi
  else ln -s "$t" "$LINK"; fi
}

for _ in $(seq 1 30); do ACCT="$(account)"; [ -n "$ACCT" ] && break; sleep 2; done  # Online Accounts may start after us
[ -n "${ACCT:-}" ] || { log "no Google account in Online Accounts; nothing mounted"; exit 1; }
T="$(target "$ACCT")"
link "$T" || exit 1
log "started for $ACCT"
while :; do
  if [ ! -d "$T" ]; then
    if mount_once "$ACCT"; then log "mounted"; else log "mount failed; retrying in ${CHECK}s"; fi
  fi
  sleep "$CHECK"
done
