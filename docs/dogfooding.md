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

After you push a change to `develop` and the workflow finishes (you can confirm at `https://github.com/titusjohnson/Readarr/actions`):

```bash
# Pull the rolling :develop tag
docker compose pull readarr
docker compose up -d readarr

# Or pin to a specific commit's image for stability:
# Edit docker-compose.yml, change the image tag to ghcr.io/titusjohnson/readarr:sha-abc1234
docker compose pull readarr
docker compose up -d readarr
```

## Rollback

Bump the compose `image:` line to a previous `sha-<short>` tag and `docker compose up -d readarr`. Images aren't garbage-collected from GHCR automatically, so old SHA tags remain pullable indefinitely.

To find previous tags:

```bash
gh api "/users/titusjohnson/packages/container/readarr/versions" \
    --jq '.[] | .metadata.container.tags' | head -20
```

## Logs and troubleshooting

```bash
# Tail container logs
docker logs -f readarr

# Tail Readarr's own log files
docker exec readarr tail -f /config/logs/readarr.txt

# Confirm /ping responds
curl http://<server-ip>:8787/ping
# Expected: 200 with empty body
```

### "Image not found" on pull

Re-authenticate to GHCR (`docker login ghcr.io ...`). The image is private; an unauthenticated pull returns 404.

### Permissions issue on `/config`

Check `docker exec readarr ls -la /config`. Everything should be owned by `abc abc`. If not, stop the container, `chown -R <PUID>:<PGID>` the host-mount path, and restart.

### First-run takes forever

Normal — initial DB migration runs ~150 schema changes serially. Subsequent restarts are fast.
