#!/usr/bin/env bash
set -euo pipefail

ROON_APP_DIR="/Roon/app"
ROON_INSTALLED="${ROON_APP_DIR}/.installed"
ROON_DOWNLOAD_URL="${ROON_DOWNLOAD_URL:-https://download.roonlabs.net/builds/RoonServer_linuxx64.tar.bz2}"

# Verify /Roon is mounted and writable
if test ! -w /Roon; then
    echo "The Roon folder doesn't exist or is not writable"
    exit 1
fi

# Ensure directory structure exists
mkdir -p /Roon/{app,data,backup}

# Download and install RoonServer on first run
if [ ! -f "$ROON_INSTALLED" ]; then
    echo "RoonServer not found — downloading..."
    curl -fL --progress-bar -o /tmp/RoonServer.tar.bz2 "$ROON_DOWNLOAD_URL"
    echo "Extracting..."
    tar xjf /tmp/RoonServer.tar.bz2 -C "$ROON_APP_DIR" --no-same-permissions --no-same-owner
    rm -f /tmp/RoonServer.tar.bz2

    # libharfbuzz.so links against libfreetype.so.6 but bundled lib has no soname suffix
    ln -sf "${ROON_APP_DIR}/RoonServer/Appliance/libfreetype.so" \
           "${ROON_APP_DIR}/RoonServer/Appliance/libfreetype.so.6"

    # Record the installed Roon version from the tarball's VERSION file
    if [ -f "${ROON_APP_DIR}/RoonServer/VERSION" ]; then
        cp "${ROON_APP_DIR}/RoonServer/VERSION" "$ROON_INSTALLED"
    else
        echo "unknown" > "$ROON_INSTALLED"
    fi
    echo "RoonServer installed successfully."
fi

# Log versions at startup
echo "Image: $(cat /etc/roon-image-version 2>/dev/null || echo 'unknown')"
echo "Roon:  $(sed -n '2p' "$ROON_INSTALLED" 2>/dev/null || echo 'unknown')"

# start.sh handles restart-on-exit-122 without a full container restart
exec "${ROON_APP_DIR}/RoonServer/start.sh"
