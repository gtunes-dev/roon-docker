#!/usr/bin/env bash
set -euo pipefail

export ROON_DATAROOT="/Roon/database"
export ROON_ID_DIR="/Roon/database"

ROON_APP_DIR="/Roon/app"
VERSION_FILE="${ROON_APP_DIR}/RoonServer/VERSION"
IMAGE_VERSION="$(cat /etc/roon-image-version 2>/dev/null || echo 'unknown')"

echo "Roon Docker image ${IMAGE_VERSION} starting."

# --- Privilege model -------------------------------------------------------
#
# This image uses the PUID/PGID convention for non-root operation. The
# Docker-native --user / user: flag is not supported because the entrypoint
# needs to start as root in order to chown its managed subdirs and drop
# privileges via setpriv. Forcing user: "0:0" (e.g., for TrueNAS) is fine —
# it still starts the container as root.
#
# Defaults (PUID=0, PGID=0) preserve the pre-PUID/PGID behavior (run as
# root). Override via env vars to drop to a different UID/GID.

if [ "$(id -u)" != "0" ]; then
    echo "Error: this image must start as root."
    echo "       Detected non-root startup (--user / user: was set to a non-root value)."
    echo "       Remove --user / user: and use PUID/PGID env vars instead."
    echo "         e.g.  -e PUID=1000 -e PGID=1000"
    exit 1
fi

# If only one of PUID/PGID is supplied, default the missing one to match.
# Most PUID/PGID images treat the pair as joined; setting just PUID=1000
# would otherwise silently leave the group at 0 (root group), which is
# almost never what the user wants.
if [ -n "${PUID-}" ] && [ -z "${PGID-}" ]; then
    PGID="$PUID"
elif [ -n "${PGID-}" ] && [ -z "${PUID-}" ]; then
    PUID="$PGID"
fi
PUID="${PUID:-0}"
PGID="${PGID:-0}"

# Target ownership for the managed subdirs is always set. This makes
# ownership tracking symmetric: unsetting PUID/PGID after a prior
# non-root run cleanly reverts /Roon/app and /Roon/database back to
# root, instead of leaving them stranded under a UID that no longer
# matches the running process.
TARGET_USER="${PUID}:${PGID}"

DROP_PRIVS=false
if [ "$PUID" != "0" ] || [ "$PGID" != "0" ]; then
    groupmod -o -g "$PGID" roon
    usermod  -o -u "$PUID" -g "$PGID" roon
    DROP_PRIVS=true
    echo "PUID/PGID set; will switch to ${TARGET_USER} before launching RoonServer."
fi

# Verify /Roon is mounted and writable
if test ! -w /Roon; then
    echo "Error: The /Roon directory is not writable."
    echo "       Check that your volume mount points at a writable host path."
    exit 1
fi

# Ensure directory structure exists
mkdir -p /Roon/{app,database}

# Read the installed branch from the VERSION file (last line).
# Strip all whitespace: a corrupt/empty VERSION file (e.g., a failed prior
# extraction) would otherwise yield a blank branch that falls through to
# the "no existing install" path *silently* while still having a
# half-populated RoonServer directory on disk. Treating blank content as
# "no install" is correct, but we log it distinctly so the confusing
# "Detected existing install (branch: )" line never appears in logs.
INSTALLED_BRANCH=""
if [ -f "$VERSION_FILE" ]; then
    INSTALLED_BRANCH="$(tail -1 "$VERSION_FILE" | tr -d '[:space:]')"
    if [ -n "$INSTALLED_BRANCH" ]; then
        echo "Detected existing RoonServer install (branch: ${INSTALLED_BRANCH})."
    else
        echo "VERSION file at ${VERSION_FILE} is empty — treating as no existing install."
    fi
else
    echo "No existing RoonServer install found under ${ROON_APP_DIR}/RoonServer."
fi

# --- Branch resolution ------------------------------------------------------
#
# ROON_INSTALL_BRANCH is treated as an env-variable-with-a-default. Unset or
# empty means "production" — same as setting it explicitly. Previous
# revisions had a "sticky" mode that kept the installed branch when the env
# var was unset; that was clever but produced different meanings for "no
# spec" depending on install state, which was confusing and made downgrades
# unreliable. The simpler "always default to production" model means the
# env var works like every other configurable: a default value the user
# can override.

# Normalize: strip surrounding whitespace, lowercase, default to production.
# Forgiving of YAML/docker-run copy-paste artifacts. Internal whitespace
# (e.g. "Early Access") still errors out via the validation case below.
ROON_INSTALL_BRANCH="$(printf '%s' "${ROON_INSTALL_BRANCH:-production}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')"
ROON_INSTALL_BRANCH="${ROON_INSTALL_BRANCH:-production}"

case "$ROON_INSTALL_BRANCH" in
    production|earlyaccess) ;;
    *)
        echo "Error: Invalid ROON_INSTALL_BRANCH='${ROON_INSTALL_BRANCH}'."
        echo "       Must be 'production' or 'earlyaccess'."
        exit 1
        ;;
esac

# Echo the resolved (post-normalization) value once so users can confirm
# whitespace stripping / casing produced what they expected. Logged before
# the install decision so it appears even if a subsequent download fails.
echo "Resolved ROON_INSTALL_BRANCH='${ROON_INSTALL_BRANCH}'."

# --- Install decision -------------------------------------------------------
#
# When ROON_DOWNLOAD_URL is set explicitly, the user is supplying their own
# binary source (typically a local mirror). The URL overrides the branch:
# we use it as-is and skip branch-mismatch reinstall logic, since the URL
# may serve any branch and the user is responsible for that consistency.
# Otherwise we derive the URL from the branch and enforce reinstalls when
# the requested branch differs from what's on disk.

NEEDS_INSTALL=false

if [ -n "${ROON_DOWNLOAD_URL+x}" ]; then
    if [ -z "$INSTALLED_BRANCH" ]; then
        NEEDS_INSTALL=true
        echo "Custom ROON_DOWNLOAD_URL set; performing fresh install from override URL."
    else
        echo "Custom ROON_DOWNLOAD_URL set; using existing install (branch '${INSTALLED_BRANCH}')."
    fi
else
    ROON_DOWNLOAD_URL="https://download.roonlabs.net/builds/${ROON_INSTALL_BRANCH}/RoonServer_linuxx64.tar.bz2"
    if [ -z "$INSTALLED_BRANCH" ]; then
        NEEDS_INSTALL=true
        echo "No install present; installing branch '${ROON_INSTALL_BRANCH}'."
    elif [ "$INSTALLED_BRANCH" != "$ROON_INSTALL_BRANCH" ]; then
        echo "Branch change detected: ${INSTALLED_BRANCH} -> ${ROON_INSTALL_BRANCH}"
        NEEDS_INSTALL=true
    else
        echo "Installed branch '${INSTALLED_BRANCH}' matches requested branch; no reinstall needed."
    fi
fi

# --- Install (if needed) ----------------------------------------------------

if [ "$NEEDS_INSTALL" = true ]; then
    # Always wipe before extracting. Handles three cases uniformly:
    # branch-switch (need to remove the old branch's binaries), corrupt
    # prior install (RoonServer/ exists but VERSION is missing/empty), and
    # fresh install (no-op). Cheaper than detecting which case applies.
    rm -rf "${ROON_APP_DIR}/RoonServer"

    echo "Downloading from ${ROON_DOWNLOAD_URL}..."
    curl -fL --retry 2 --progress-bar -o /tmp/RoonServer.tar.bz2 "$ROON_DOWNLOAD_URL"
    echo "Extracting to ${ROON_APP_DIR}..."
    tar xjf /tmp/RoonServer.tar.bz2 -C "$ROON_APP_DIR" --no-same-permissions --no-same-owner
    rm -f /tmp/RoonServer.tar.bz2

    echo "RoonServer installed successfully."
fi

# Align ownership of the dirs we manage to the running user — always.
# Done after install so files extracted by tar in this run are also
# captured. /Roon, /Music, and /RoonBackups themselves are the user's
# responsibility — only /Roon/app and /Roon/database (and their
# contents) are chown'd here.
#
# Always recursive (no skip-if-already-correct shortcut): a self-update
# or partial extraction can leave files with mixed ownership that a
# top-level stat check would miss. Wall time is logged so users with
# very large databases can see the cost in their startup logs.
#
# Symmetric: also runs when TARGET_USER=0:0, so unsetting PUID/PGID
# after a prior non-root run reverts ownership cleanly.
echo "Aligning ownership of /Roon/app and /Roon/database to ${TARGET_USER}..."
CHOWN_START=$(date +%s)
chown -R "$TARGET_USER" /Roon/app /Roon/database
echo "Ownership alignment complete in $(($(date +%s) - CHOWN_START))s."

# --- Final state log --------------------------------------------------------
# Line format is contract-ish: runtime tests grep for "^Branch: production"
# and "^Branch: earlyaccess". Don't change the prefix or spacing without
# updating tests/runtime.sh to match. The branch reported here is read
# from VERSION (post-install) so a custom ROON_DOWNLOAD_URL pulling a
# different branch than ROON_INSTALL_BRANCH shows the *actual* installed
# branch, not the requested label.

ACTUAL_BRANCH="$ROON_INSTALL_BRANCH"
if [ -f "$VERSION_FILE" ]; then
    POST_INSTALL_BRANCH="$(tail -1 "$VERSION_FILE" | tr -d '[:space:]')"
    if [ -n "$POST_INSTALL_BRANCH" ]; then
        ACTUAL_BRANCH="$POST_INSTALL_BRANCH"
    fi
fi

echo "Image:   ${IMAGE_VERSION}"
echo "Branch: ${ACTUAL_BRANCH}"
echo "Roon:    $(sed -n '2p' "$VERSION_FILE" 2>/dev/null || echo 'unknown')"

ROON_DEFAULT_MUSIC_FOLDER_WATCH_PATH=/Music
export ROON_DEFAULT_MUSIC_FOLDER_WATCH_PATH
HOME=/
export HOME

# start.sh handles restarts internally without a full container restart.
# When PUID/PGID is set, drop to that user via setpriv before exec'ing.
if [ "$DROP_PRIVS" = true ]; then
    exec setpriv --reuid="$PUID" --regid="$PGID" --init-groups -- "${ROON_APP_DIR}/RoonServer/start.sh"
else
    exec "${ROON_APP_DIR}/RoonServer/start.sh"
fi
