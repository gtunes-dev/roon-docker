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
#   cifs-utils      — SMB/CIFS network share mounting
#   ca-certificates — HTTPS for streaming services and cloud APIs
RUN tdnf install -y \
    bash curl tar xz bzip2 tzdata icu \
    alsa-lib cifs-utils ca-certificates \
 && (chmod u-s /usr/sbin/mount.cifs 2>/dev/null || true) \
 && tdnf clean all \
 && rm -rf /var/cache/tdnf /var/log/tdnf.log \
           /usr/share/doc /usr/share/man

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
