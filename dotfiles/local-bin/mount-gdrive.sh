#!/usr/bin/env bash
# Mount Google Drive via rclone with responsiveness-tuned flags.
# Managed by Claude Code — see notes at bottom for the required client_id upgrade.
set -uo pipefail

RCLONE="$HOME/.local/bin/rclone"
MNT="$HOME/GoogleDrive"
LOG="$HOME/.cache/rclone/mount.log"
mkdir -p "$MNT" "$(dirname "$LOG")"

# Already mounted? Do nothing.
if mountpoint -q "$MNT"; then
    exit 0
fi

# Keep the log from growing without bound (it is INFO-chatty on cache sweeps).
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 5000000 ]; then
    mv -f "$LOG" "$LOG.1"
fi

# Launch the mount detached from this session so it survives after the
# script exits. No --daemon (it conflicts with everything) and no --rc
# server (no open port).
#
# --vfs-refresh walks the whole remote in the background as soon as the mount
# comes up, so the directory cache (held 1000h) is already populated the first
# time a folder is opened. It replaces the old external `find` pre-warm, which
# never actually ran: systemd tore down the script's children the instant the
# launcher exited, leaving only the setsid'd mount alive and the cache cold.
setsid "$RCLONE" mount drive: "$MNT" \
    --vfs-cache-mode full \
    --vfs-cache-max-size 10G \
    --vfs-cache-max-age 72h \
    --vfs-cache-poll-interval 1m \
    --dir-cache-time 1000h \
    --poll-interval 15s \
    --attr-timeout 1000h \
    --vfs-refresh \
    --vfs-fast-fingerprint \
    --vfs-read-chunk-size 128M \
    --vfs-read-chunk-size-limit 2G \
    --vfs-read-ahead 128M \
    --buffer-size 64M \
    --transfers 8 \
    --checkers 16 \
    --log-file "$LOG" \
    --log-level NOTICE \
    </dev/null >/dev/null 2>&1 &

exit 0

# --- REQUIRED soon: set up a personal Google API client_id ---
# The remote uses rclone's shared OAuth client, which (a) Google rate-limits
# heavily — the main source of lag: ~100ms forced sleep between every API call,
# plus rateLimitExceeded backoffs — and (b) is being RETIRED during 2026, so
# Drive will eventually stop working entirely without your own client_id. Fix:
#   1. https://console.cloud.google.com  -> create a project
#   2. Enable "Google Drive API"
#   3. OAuth consent screen: External; add your own email as a test user
#   4. Credentials -> Create OAuth client ID -> Application type: Desktop app
#   5. rclone config reconnect drive:   (paste the client_id + client_secret)
# Afterwards this script can safely add:  --drive-pacer-min-sleep 10ms
# which cuts the background warm-up from minutes to seconds.
