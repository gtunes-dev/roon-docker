# syntax=docker/dockerfile:1

FROM --platform=linux/amd64 photon:5.0

ARG VERSION=dev
ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="RoonServer"
LABEL org.opencontainers.image.authors="gTunesDev"
LABEL org.opencontainers.image.vendor="gTunesDev"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.description="RoonServer Docker image — PhotonOS base. Personal fork of RoonLabs/roon-docker."
LABEL org.opencontainers.image.source="https://github.com/gtunes-dev/roon-docker"
LABEL org.opencontainers.image.revision="${GIT_SHA}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.url="https://roon.app"
LABEL org.opencontainers.image.licenses="Proprietary"

# Runtime dependencies:
#   curl            — downloads RoonServer on first run
#   tar             — GNU tar; Photon's base /usr/bin/tar is a toybox symlink
#                     that lacks --wildcards (used in the ffmpeg layer below to
#                     extract a single binary from the archive) and
#                     --no-same-permissions/--no-same-owner (used by
#                     entrypoint.sh when extracting RoonServer onto NAS mounts)
#   bzip2           — extracts the .tar.bz2 tarball
#   tzdata          — IANA timezone data for TZ environment variable
#   icu             — .NET globalization
#   alsa-lib        — ALSA audio, required by libraatmanager.so
#   freetype2       — provides libfreetype.so.6 soname that bundled libharfbuzz links against
#   cifs-utils      — SMB/CIFS network share mounting
#   ca-certificates — HTTPS for streaming services and cloud APIs
#   shadow          — usermod/groupmod to align placeholder user with PUID/PGID at runtime
#   traceroute      — Roon spawns traceroute for network diagnostics; the
#                     toybox symlink at /usr/bin/traceroute can't run as
#                     non-root (raw socket needs CAP_NET_RAW; can't setcap a
#                     toybox symlink without granting caps to every toybox
#                     command). Installing the real package overwrites the
#                     symlink with a standalone binary we can setcap.
RUN tdnf install -y \
    bash curl tar xz bzip2 tzdata icu \
    alsa-lib freetype2 cifs-utils ca-certificates \
    shadow traceroute \
 && (chmod u-s /usr/sbin/mount.cifs 2>/dev/null || true) \
 && setcap cap_net_raw+ep /usr/bin/traceroute \
 && tdnf clean all \
 && rm -rf /var/cache/tdnf /var/log/tdnf.log \
           /usr/share/doc /usr/share/man

# gosu provides clean exec-style privilege drop for the PUID/PGID feature.
# Photon's util-linux is built without setpriv, and no Photon package ships
# it, so we install gosu directly. Pinned by version; SHA verification could
# be added later for tamper-evidence (HTTPS to GitHub releases is the current
# trust anchor).
ARG GOSU_VERSION=1.17
RUN curl -fL -o /usr/local/bin/gosu \
        "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-amd64" \
 && chmod +x /usr/local/bin/gosu \
 && /usr/local/bin/gosu --version

# Placeholder user/group for the optional PUID/PGID feature in entrypoint.sh.
# At runtime, usermod/groupmod adjust these IDs to whatever PUID/PGID requests
# (or this user stays unused if PUID/PGID is unset and the container runs as root).
RUN groupadd -r roon && useradd -r -g roon -d /Roon -s /bin/bash -N roon

RUN curl -L -o /tmp/ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz \
 && tar xf /tmp/ffmpeg.tar.xz --wildcards -C /tmp "ffmpeg*/ffmpeg" \
 && mv /tmp/ffmpeg-*/ffmpeg /usr/local/bin/ \
 && rm -rf /tmp/ffmpeg*

RUN echo "${VERSION}" > /etc/roon-image-version

COPY entrypoint.sh /entrypoint.sh

# Informational only — requires --net=host for multicast discovery
EXPOSE 9003/udp 9100-9200/tcp 9200-9250/tcp 9330-9339/tcp 55000/tcp

VOLUME /Roon /RoonBackups /Music

# Healthcheck uses /proc directly instead of pgrep to avoid procps dependency
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD grep -ql '[R]oonServer.dll' /proc/[0-9]*/cmdline 2>/dev/null || exit 1

# entrypoint.sh downloads RoonServer on first run (to /Roon/app), then
# exec's into start.sh — the stock bash launcher that handles
# .NET runtime discovery, ulimit, self-update swap, and restart.
ENTRYPOINT ["/entrypoint.sh"]
