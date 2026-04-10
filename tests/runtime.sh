#!/usr/bin/env bash
# Starts the container and validates the download/install/startup flow.
# This test downloads ~200MB from download.roonlabs.net.
set -euo pipefail

IMAGE="${1:?Usage: runtime.sh <image:tag>}"
CONTAINER="roon-runtime-test"
ROON_DIR="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
    docker rm -f "$CONTAINER" 2>/dev/null || true
    rm -rf "$ROON_DIR"
}
trap cleanup EXIT

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

echo "=== Runtime tests: $IMAGE ==="
echo "    Temp dir: $ROON_DIR"

# Start container — entrypoint will download RoonServer
docker run -d --name "$CONTAINER" \
    -v "$ROON_DIR:/Roon" \
    "$IMAGE"

# Wait for download and extraction (timeout after 120s)
echo "    Waiting for RoonServer download..."
TIMEOUT=120
ELAPSED=0
while [ ! -f "$ROON_DIR/app/.installed" ] && [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    echo "    ... ${ELAPSED}s"
done

# Check results
check "sentinel file created" \
    test -f "$ROON_DIR/app/.installed"

check "sentinel contains version info" \
    grep -q "build" "$ROON_DIR/app/.installed"

check "RoonServer directory exists" \
    test -d "$ROON_DIR/app/RoonServer"

check "start.sh exists" \
    test -f "$ROON_DIR/app/RoonServer/start.sh"

check "Server/RoonServer launcher exists" \
    test -f "$ROON_DIR/app/RoonServer/Server/RoonServer"

check "RoonDotnet runtime exists" \
    test -d "$ROON_DIR/app/RoonServer/RoonDotnet"

check "VERSION file present in tarball" \
    test -f "$ROON_DIR/app/RoonServer/VERSION"

check "libfreetype.so.6 symlink created" \
    test -L "$ROON_DIR/app/RoonServer/Appliance/libfreetype.so.6"

# Grab logs before stopping
docker logs "$CONTAINER" > "$ROON_DIR/container.log" 2>&1 || true

check "logs contain image version" \
    grep -q "^Image:" "$ROON_DIR/container.log"

check "logs contain roon version" \
    grep -q "^Roon:" "$ROON_DIR/container.log"

# Signal handling: docker stop should exit cleanly (0 or 143), not hard-killed (137)
echo "    Testing clean shutdown..."
docker stop -t 30 "$CONTAINER" 2>/dev/null || true
EXIT_CODE=$(docker inspect "$CONTAINER" --format '{{.State.ExitCode}}')
check "clean shutdown (exit 0 or 143, got $EXIT_CODE)" \
    test "$EXIT_CODE" -eq 0 -o "$EXIT_CODE" -eq 143

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
