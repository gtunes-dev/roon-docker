#!/usr/bin/env bash
# Quick checks against the built image — no container start, no network.
set -euo pipefail

IMAGE="${1:?Usage: smoke.sh <image:tag>}"
PASS=0
FAIL=0

check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "  PASS  $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $desc"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== Smoke tests: $IMAGE ==="

# Entrypoint
check "entrypoint exists and is executable" \
    docker run --rm --entrypoint stat "$IMAGE" -c '%a' /entrypoint.sh

# Required binaries
for bin in bash curl bzip2 tar ffmpeg; do
    check "$bin is available" \
        docker run --rm --entrypoint which "$IMAGE" "$bin"
done

# Environment variables
check "ROON_DATAROOT is /Roon/data" \
    docker run --rm --entrypoint sh "$IMAGE" -c '[ "$ROON_DATAROOT" = "/Roon/data" ]'

check "ROON_ID_DIR is /Roon/data" \
    docker run --rm --entrypoint sh "$IMAGE" -c '[ "$ROON_ID_DIR" = "/Roon/data" ]'

# Image version file
check "/etc/roon-image-version exists" \
    docker run --rm --entrypoint cat "$IMAGE" /etc/roon-image-version

# OCI labels
check "image has version label" \
    docker inspect "$IMAGE" --format '{{ index .Config.Labels "org.opencontainers.image.version" }}'

check "image has source label" \
    docker inspect "$IMAGE" --format '{{ index .Config.Labels "org.opencontainers.image.source" }}'

# Cleanup was effective
check "apt lists cleaned" \
    docker run --rm --entrypoint sh "$IMAGE" -c '[ -z "$(ls /var/lib/apt/lists/)" ]'

# SUID stripped from mount.cifs
check "mount.cifs has no SUID bit" \
    docker run --rm --entrypoint sh "$IMAGE" -c '[ ! -u /usr/sbin/mount.cifs ]'

# Failure path: container should exit non-zero without /Roon mounted
FAIL_EXIT=0
FAIL_OUTPUT=$(docker run --rm "$IMAGE" 2>&1) || FAIL_EXIT=$?
check "exits with error when /Roon not mounted" \
    test "$FAIL_EXIT" -ne 0

check "prints writable error when /Roon not mounted" \
    sh -c 'echo "$1" | grep -q "not writable"' _ "$FAIL_OUTPUT"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
