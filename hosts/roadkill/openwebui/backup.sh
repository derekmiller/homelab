#!/usr/bin/env bash
#
# Snapshot the Open WebUI data volume — chats, uploads, and webui.db — verify
# the archive, rotate old copies, and optionally copy the new one off the host.
#
# Run by openwebui-backup.service, but safe to run by hand:
#
#   ./backup.sh
#
# Environment:
#   OPENWEBUI_REPO_DIR      checkout to run compose in   (/opt/homelab/hosts/roadkill/openwebui)
#   OPENWEBUI_BACKUP_DIR    where archives are written   (/var/lib/openwebui-backup)
#   OPENWEBUI_BACKUP_KEEP   days of archives to keep     (14)
#   OPENWEBUI_VOLUME        Docker volume to snapshot    (open-webui)
#   OPENWEBUI_BACKUP_REMOTE rsync target, e.g. user@mac:/vol/openwebui
#
# The container is stopped for the duration. SQLite cannot be trusted to a
# filesystem copy while it is being written, and a database that is corrupt in
# one table is discovered weeks later. The window is seconds at 03:45.
#
set -euo pipefail

repo_dir="${OPENWEBUI_REPO_DIR:-/opt/homelab/hosts/roadkill/openwebui}"
backup_dir="${OPENWEBUI_BACKUP_DIR:-/var/lib/openwebui-backup}"
keep="${OPENWEBUI_BACKUP_KEEP:-14}"
volume="${OPENWEBUI_VOLUME:-open-webui}"
remote="${OPENWEBUI_BACKUP_REMOTE:-}"

# Pinned: an unpinned alpine in a backup path means the thing that produces
# your only copy changes without you.
archiver=alpine:3.24

cd "$repo_dir"
mkdir -p "$backup_dir"

stamp=$(date -u +%Y-%m-%dT%H%M%SZ)
target="${backup_dir}/${volume}-${stamp}.tgz"

stopped=0
cleanup() {
    if [[ $stopped -eq 1 ]]; then
        docker compose start openwebui >/dev/null 2>&1 || true
        stopped=0
    fi
}
trap cleanup EXIT

fail() {
    printf 'backup failed: %s\n' "$1" >&2
    rm -f "$target"
    exit 1
}

printf 'stopping openwebui for a consistent copy\n'
docker compose stop openwebui >/dev/null || fail "could not stop openwebui"
stopped=1

# Archive as root inside a throwaway container: the volume is not readable by
# the invoking user, and the container sees it at the same path the app does.
if ! docker run --rm -v "$volume":/data:ro -v "$backup_dir":/backup "$archiver" \
    tar czf "/backup/$(basename "$target")" -C /data .; then
    fail "tar returned nonzero"
fi

# Restart before verifying: verification failures are about the archive, and
# the service should not stay down for them.
cleanup

[[ -s $target ]] || fail "archive is empty"

gzip -t "$target" || fail "archive is not valid gzip"

# webui.db is the file whose absence makes an archive useless. Checking it
# catches a volume that was empty or unmounted, which tar would happily archive
# as nothing at all.
tar -tzf "$target" | grep -qx './webui.db' || fail "archive has no ./webui.db"

size=$(du -h "$target" | cut -f1)
printf 'wrote %s (%s)\n' "$target" "$size"

# Rotation runs after the new archive is verified, so a failing backup never
# deletes the last good copy.
deleted=$(find "$backup_dir" -maxdepth 1 -type f -name '*.tgz' \
    -mtime +"$keep" -print -delete | wc -l)
printf 'rotated %s archive(s) older than %s days\n' "$deleted" "$keep"

if [[ -n $remote ]]; then
    command -v rsync >/dev/null 2>&1 \
        || fail "OPENWEBUI_BACKUP_REMOTE is set but rsync is not installed"
    rsync -a --partial "$target" "${remote%/}/" \
        || fail "off-box copy to ${remote} failed"
    printf 'copied to %s\n' "$remote"
fi
