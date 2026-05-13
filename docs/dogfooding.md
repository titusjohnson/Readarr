# Dogfooding Readarr on a Home Server

This fork publishes a Docker image to GHCR on every push to `develop`. The image is private; pulling requires authenticating to `ghcr.io` with a personal access token (PAT) scoped to `read:packages`.

## One-time server setup

### 1. Authenticate the server to GHCR

```bash
# On the server, with a PAT that has read:packages scope
echo "$GHCR_PAT" | docker login ghcr.io -u titusjohnson --password-stdin
```

### 2. Add the service to your existing `docker-compose.yml`

Append a `readarr` block alongside your existing `sonarr`/`radarr` services. Match `PUID`/`PGID` and `TZ` to what those services use. Adjust the `volumes` paths to your library layout.

```yaml
readarr:
  image: ghcr.io/titusjohnson/readarr:develop
  container_name: readarr
  environment:
    - PUID=1000        # match your sonarr/radarr
    - PGID=1000
    - TZ=America/Los_Angeles   # match your sonarr/radarr
  volumes:
    - ./readarr-config:/config
    - /path/to/books:/books
    - /path/to/downloads:/downloads
  ports:
    - "8787:8787"
  restart: unless-stopped
  networks:
    - <your-arr-network>      # same network sonarr/radarr use
```

### 3. First start

```bash
docker compose pull readarr
docker compose up -d readarr
```

First run takes a few minutes — Readarr applies ~150 SQLite migrations to set up the database.

Visit `http://<server-ip>:8787/` to confirm the UI loads.

## Update workflow

After you push a change to `develop` and the workflow finishes (you can confirm at `https://github.com/titusjohnson/Readarr/actions`), pick one of:

**Option A — rolling update (default).** Pull whatever `:develop` currently points at:

```bash
docker compose pull readarr
docker compose up -d readarr
```

**Option B — pin to a specific SHA for stability.** Find the tag you want via the GHCR query in the Rollback section, edit `docker-compose.yml` so the `image:` line is `ghcr.io/titusjohnson/readarr:sha-abc1234`, then:

```bash
docker compose pull readarr
docker compose up -d readarr
```

## Rollback

Bump the compose `image:` line to a previous `sha-<short>` tag and `docker compose up -d readarr`. Images aren't garbage-collected from GHCR automatically, so old SHA tags remain pullable indefinitely.

To find previous tags:

```bash
gh api "/users/titusjohnson/packages/container/readarr/versions" \
    --jq '.[0:10] | .[] | {id, created_at, tags: .metadata.container.tags}'
```

## Logs and troubleshooting

```bash
# Tail container logs
docker logs -f readarr

# Tail Readarr's own log files
docker exec readarr tail -f /config/logs/readarr.txt

# Confirm /ping responds
curl http://<server-ip>:8787/ping
# Expected: 200, body: {"status":"OK"}
```

### "Image not found" on pull

Re-authenticate to GHCR (`docker login ghcr.io ...`). The image is private; an unauthenticated pull returns 404.

### Permissions issue on `/config`

Inside the container the `/config` directory and files Readarr creates should be owned by your `PUID`/`PGID` (displayed as `abc abc` once the LSIO init has remapped the runtime user). If `docker logs readarr` shows `Permission denied` errors, the host-mount path isn't writable by `PUID`. Stop the container, run `sudo chown -R <PUID>:<PGID> ./readarr-config` (or whatever you mounted), and `docker compose up -d readarr`.

### First-run takes forever

Normal — initial DB migration runs ~150 schema changes serially. Subsequent restarts are fast.
