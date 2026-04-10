# RoonServer Docker Image

Official Docker image for [Roon Server](https://roon.app).

```
ghcr.io/roonlabs/roonserver
```

> **Note:** This image is **amd64 (x86_64) only**. ARM-based devices (Raspberry Pi, ARM NAS models like Synology J-series) are not supported.

## Quick Start

Use the **[Docker Setup Guide](https://roonlabs.github.io/roon-docker/)** to generate a `docker run` or `docker compose` command tailored to your system.

On first start, the container downloads and installs RoonServer automatically. Subsequent starts skip the download and launch immediately.

## Requirements

- **Linux host** (amd64 / x86_64) — NAS devices (Synology, QNAP, Unraid, TrueNAS) work well
- **Host networking** (`--net=host`) — required for Roon's multicast device discovery
- **Restart policy** (`--restart unless-stopped`) — Roon exits with code 122 to request restarts
- **Init process** (`--init`) — ensures clean signal handling and zombie process reaping
- **Stop timeout** (`--stop-timeout 45`) — gives Roon time to flush its database on shutdown

Docker Desktop for macOS and Windows does not support multicast and will not work for production use.

## Networking

Roon requires host networking (`--net=host`) for multicast device discovery. Bridge networking will not work. No port mapping (`-p`) is needed.

## Timezone

Set the `TZ` environment variable to your [timezone](https://en.wikipedia.org/wiki/List_of_tz_database_time_zones). This ensures correct timestamps in Roon logs, last.fm scrobbles, and backup schedules.

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `TZ` | `UTC` | Timezone for logs and schedules |
| `ROON_DATAROOT` | `/Roon/data` | Data directory (set in image, don't change) |
| `ROON_ID_DIR` | `/Roon/data` | Identity directory (set in image, don't change) |
| `ROON_DOWNLOAD_URL` | *(default CDN)* | Override the RoonServer download URL |

## Volumes

All Roon state lives under a single `/Roon` mount:

| Path | Purpose |
|------|---------|
| `/Roon/data` | Database, settings, cache, and identity |
| `/Roon/backup` | Roon backup destination |
| `/Roon/app` | Downloaded RoonServer binaries |
| `/music` | Your music library (mounted read-only) |

```bash
-v /Roon:/Roon \
-v /Music:/music:ro
```

**The `/Roon/data` directory is critical.** It contains your Roon identity, database, library, playlists, DSP settings, streaming credentials, and zone configurations. If this volume is lost:

- Roon generates a new machine identity — you must re-authorize from a Roon remote
- Your old machine may consume a license seat until deauthorized (via [account settings](https://accounts.roonlabs.com))
- All library data, playlists, and settings are lost unless restored from a Roon backup

Always back up your `/Roon` volume. Use the Roon backup feature (Settings > Backups) pointed at `/Roon/backup`.

## Updating

Roon Server updates itself automatically. When an update is available, the container will download and apply it — no action needed.

Updates persist across `docker stop` / `docker start`. If you recreate the container (`docker rm` + `docker run`), Roon will re-download the latest version on first start.

## Troubleshooting

**Container exits immediately** — check `/Roon` is mounted and writable.

**Remotes can't find the server** — verify `--net=host` is set. Bridge networking doesn't support multicast discovery.

**High CPU after first start** — background audio analysis runs after importing a library. Adjust speed in Settings > Library.

**First start is slow** — RoonServer (~200MB) is downloaded on first run. Subsequent starts are instant.

**Logs** — `docker logs roonserver` or inside the volume at `/Roon/data/RoonServer/Logs/`.

## License

Copyright Roon Labs LLC. All rights reserved.
