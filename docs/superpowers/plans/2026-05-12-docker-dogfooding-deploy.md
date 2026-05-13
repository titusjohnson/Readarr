# Docker Dogfooding Deploy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a `git push → GHCR image → server pull` loop so the fork owner can dogfood Readarr on a personal home server alongside Sonarr/Radarr.

**Architecture:** Framework-dependent .NET 6 publish built on the GH Actions runner, packaged into a linuxserver.io-base Docker image (with ASP.NET Core 6 runtime + libicu72 installed at image-build time), pushed to private GHCR on every push to `develop` (tagged `:develop` rolling + `:sha-<short>` immutable). Server pulls and runs via the existing `docker-compose.yml`.

> **Plan amendment (2026-05-12):** The original design used self-contained publish to avoid runtime install. Task 2 smoke test surfaced an assembly-version conflict — the .NET 6 runtime pack overwrites the NuGet 7.0.0 version of `Microsoft.Extensions.DependencyInjection.Abstractions`, causing startup `FileLoadException`. Switched to framework-dependent. Microsoft has removed `aspnetcore-runtime-6.0` from the Debian-12 apt repo (the EOL risk in the spec came true), so the runtime is installed via `dotnet-install.sh` from `dot.net/v1/dotnet-install.sh`. See spec amendments A1 and A2.

**Tech Stack:** .NET 6 SDK, Node 20 + yarn 1, Docker Buildx, s6-overlay v3, `lscr.io/linuxserver/baseimage-debian:bookworm`, GitHub Actions.

**Spec:** [`docs/superpowers/specs/2026-05-12-docker-dogfooding-deploy-design.md`](../specs/2026-05-12-docker-dogfooding-deploy-design.md)

---

## Notes for the implementer

- The Readarr build outputs to `_output/net6.0/<rid>/publish/` (backend) and `_output/UI/` (frontend). The Docker build context is `docker/`, so we stage artifacts under `docker/context/` before `docker buildx build`.
- The LSIO base image runs services under user `abc` (UID/GID 911 by default, remapped to `PUID`/`PGID` at runtime by `init-adduser`). We use `s6-setuidgid abc` in the service `run` script.
- All build commands assume `.NET 6 SDK 6.0.x` and `node 20 + yarn 1.x` are on PATH. On macOS dev, .NET 6 lives at `~/.dotnet/dotnet` (set `DOTNET_ROOT=$HOME/.dotnet`); in CI, `actions/setup-dotnet@v4` handles it.
- "Verify by running X" steps treat infra artifacts like tests: confirm the artifact does what it should before committing.

---

## Task 1: Scaffold the Docker image files

**Files:**
- Create: `docker/.dockerignore`
- Create: `docker/Dockerfile`
- Create: `docker/build-local.sh`
- Create: `docker/root/etc/s6-overlay/scripts/init-readarr-config`
- Create: `docker/root/etc/s6-overlay/s6-rc.d/init-readarr-config/type`
- Create: `docker/root/etc/s6-overlay/s6-rc.d/init-readarr-config/up`
- Create: `docker/root/etc/s6-overlay/s6-rc.d/svc-readarr/type`
- Create: `docker/root/etc/s6-overlay/s6-rc.d/svc-readarr/run`
- Create: `docker/root/etc/s6-overlay/s6-rc.d/svc-readarr/dependencies.d/init-readarr-config` (empty)
- Create: `docker/root/etc/s6-overlay/s6-rc.d/init-readarr-config/dependencies.d/init-adduser` (empty — ensures the LSIO base's PUID/PGID remapping runs before our chown)
- Create: `docker/root/etc/s6-overlay/s6-rc.d/user/contents.d/init-readarr-config` (empty)
- Create: `docker/root/etc/s6-overlay/s6-rc.d/user/contents.d/svc-readarr` (empty)

### Steps

- [ ] **Step 1: Create the directory structure**

```bash
mkdir -p docker/root/etc/s6-overlay/scripts
mkdir -p docker/root/etc/s6-overlay/s6-rc.d/init-readarr-config
mkdir -p docker/root/etc/s6-overlay/s6-rc.d/svc-readarr/dependencies.d
mkdir -p docker/root/etc/s6-overlay/s6-rc.d/user/contents.d
```

- [ ] **Step 2: Write `docker/.dockerignore`**

```
# Only the staged context/ and root/ should ship into the image
*
!Dockerfile
!root/
!root/**
!context/
!context/**
```

- [ ] **Step 3: Write `docker/Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE=lscr.io/linuxserver/baseimage-debian:bookworm
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.source="https://github.com/titusjohnson/Readarr"
LABEL org.opencontainers.image.description="Readarr (revival fork) — dogfooding image"
LABEL org.opencontainers.image.licenses="GPL-3.0"

# Runtime dependencies.
#
# Self-contained publish has a known bug for this codebase: the .NET 6 runtime pack
# overwrites NuGet's Microsoft.Extensions.DependencyInjection.Abstractions 7.0.0 with
# the framework's 6.0.0 version during publish, causing assembly-version mismatches
# at startup. We use framework-dependent publish and ship the ASP.NET Core 6 runtime
# inside the image.
#
# .NET 6 is EOL (Nov 2024); Microsoft has removed it from their Debian apt repo but
# the binaries remain available on builds.dotnet.microsoft.com. We install via the
# dotnet-install.sh script, which is Microsoft's documented path for EOL versions.
#
# libicu72 satisfies .NET 6's globalization requirement (Readarr ships translations,
# so invariant mode is not an option).
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates libicu72 && \
    rm -rf /var/lib/apt/lists/* && \
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh && \
    chmod +x /tmp/dotnet-install.sh && \
    /tmp/dotnet-install.sh \
        --runtime aspnetcore \
        --channel 6.0 \
        --install-dir /usr/share/dotnet \
        --no-path && \
    ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet && \
    rm /tmp/dotnet-install.sh

ENV DOTNET_ROOT=/usr/share/dotnet

# Framework-dependent .NET 6 publish output, built on the runner (or via build-local.sh).
# Layout in build context: docker/context/publish/ for the backend, docker/context/UI/ for the frontend.
COPY context/publish/ /app/readarr/bin/
COPY context/UI/ /app/readarr/bin/UI/
COPY root/ /

RUN chmod +x /app/readarr/bin/Readarr && \
    find /etc/s6-overlay/s6-rc.d -type f -name run -exec chmod +x {} + && \
    find /etc/s6-overlay/scripts -type f -exec chmod +x {} +

EXPOSE 8787

VOLUME ["/config", "/books", "/downloads"]
```

- [ ] **Step 4: Write `docker/root/etc/s6-overlay/s6-rc.d/svc-readarr/type`**

```
longrun
```

(File content is the single word `longrun`. No trailing blank line needed but harmless.)

- [ ] **Step 5: Write `docker/root/etc/s6-overlay/s6-rc.d/svc-readarr/run`**

```bash
#!/usr/bin/with-contenv bash
# shellcheck shell=bash

exec s6-setuidgid abc \
    /app/readarr/bin/Readarr -nobrowser -data=/config
```

- [ ] **Step 6: Write `docker/root/etc/s6-overlay/s6-rc.d/init-readarr-config/type`**

```
oneshot
```

- [ ] **Step 7: Write `docker/root/etc/s6-overlay/s6-rc.d/init-readarr-config/up`**

```
/etc/s6-overlay/scripts/init-readarr-config
```

- [ ] **Step 8: Write `docker/root/etc/s6-overlay/scripts/init-readarr-config`**

```bash
#!/usr/bin/with-contenv bash
# shellcheck shell=bash

mkdir -p /config
chown -R abc:abc /config
```

- [ ] **Step 9: Create the three empty marker files**

```bash
touch docker/root/etc/s6-overlay/s6-rc.d/svc-readarr/dependencies.d/init-readarr-config
touch docker/root/etc/s6-overlay/s6-rc.d/user/contents.d/init-readarr-config
touch docker/root/etc/s6-overlay/s6-rc.d/user/contents.d/svc-readarr
```

- [ ] **Step 10: Write `docker/build-local.sh`**

```bash
#!/usr/bin/env bash
# Builds Readarr (backend + frontend), stages artifacts into docker/context/,
# and builds the local Docker image as readarr:local.
#
# Requires DOTNET_ROOT pointing at a .NET 6 SDK, dotnet on PATH, yarn on PATH.
# On macOS dev: DOTNET_ROOT=$HOME/.dotnet, PATH=$HOME/.dotnet:$PATH.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

RID="${RID:-linux-x64}"
TAG="${TAG:-readarr:local}"

echo "==> Building backend (RID=$RID, framework-dependent)"
# Framework-dependent publish: relies on aspnetcore-runtime-6.0 being present in the
# runtime image. Self-contained publish currently breaks for this codebase due to an
# assembly-version conflict on Microsoft.Extensions.DependencyInjection.Abstractions
# (the .NET 6 runtime pack overwrites the NuGet 7.0.0 version with the framework 6.0.0).
dotnet msbuild -restore src/Readarr.sln \
    -p:Configuration=Release \
    -p:Platform=Posix \
    -p:RuntimeIdentifiers="$RID" \
    -p:SelfContained=false \
    -t:PublishAllRids \
    -nologo -v:minimal

echo "==> Building frontend"
yarn install --frozen-lockfile --network-timeout 600000
yarn run build --env production

echo "==> Staging Docker context"
rm -rf docker/context
mkdir -p docker/context
cp -R "_output/net6.0/$RID/publish" docker/context/publish
cp -R _output/UI docker/context/UI

echo "==> Building Docker image $TAG"
docker buildx build --load -t "$TAG" docker/

echo "==> Done. Run:"
echo "   docker run --rm -p 8787:8787 -v \$(pwd)/.local-readarr-config:/config $TAG"
```

- [ ] **Step 11: Make scripts executable**

```bash
chmod +x docker/build-local.sh
chmod +x docker/root/etc/s6-overlay/scripts/init-readarr-config
chmod +x docker/root/etc/s6-overlay/s6-rc.d/svc-readarr/run
```

(The Dockerfile re-applies +x at image-build time too — this just keeps the on-disk state consistent.)

- [ ] **Step 12: Verify file layout**

```bash
find docker -type f | sort
```

Expected output (exactly these 11 paths):
```
docker/.dockerignore
docker/Dockerfile
docker/build-local.sh
docker/root/etc/s6-overlay/s6-rc.d/init-readarr-config/type
docker/root/etc/s6-overlay/s6-rc.d/init-readarr-config/up
docker/root/etc/s6-overlay/s6-rc.d/svc-readarr/dependencies.d/init-readarr-config
docker/root/etc/s6-overlay/s6-rc.d/svc-readarr/run
docker/root/etc/s6-overlay/s6-rc.d/svc-readarr/type
docker/root/etc/s6-overlay/s6-rc.d/user/contents.d/init-readarr-config
docker/root/etc/s6-overlay/s6-rc.d/user/contents.d/svc-readarr
docker/root/etc/s6-overlay/scripts/init-readarr-config
```

- [ ] **Step 13: Commit**

```bash
git add docker/
git commit -m "Add Dockerfile and s6-overlay service definitions for dogfooding image"
```

---

## Task 2: Local end-to-end smoke test

This task does NOT modify any tracked files — it's purely a verification gate that proves the Task 1 artifacts produce a working image. If anything fails, fix Task 1's files and re-run.

**Files:** none modified. Working directories created and cleaned up: `docker/context/`, `.local-readarr-config/`.

### Steps

- [ ] **Step 1: Confirm dev toolchain is present**

```bash
$HOME/.dotnet/dotnet --version
node --version
yarn --version
docker --version
docker buildx version
```

Expected: dotnet 6.0.x; node ≥ 18; yarn 1.x; docker 24+; buildx present.

- [ ] **Step 2: Run the local build helper**

```bash
DOTNET_ROOT=$HOME/.dotnet PATH=$HOME/.dotnet:$PATH bash docker/build-local.sh
```

Expected: completes without error in ~5–8 minutes. Final line is `==> Done.` plus the run hint. `docker images | grep readarr` shows `readarr local <size>`.

- [ ] **Step 3: Start the container with a throwaway config dir**

```bash
mkdir -p .local-readarr-config
docker run -d --name readarr-smoke \
    -p 18787:8787 \
    -e PUID=$(id -u) -e PGID=$(id -g) -e TZ=UTC \
    -v "$(pwd)/.local-readarr-config:/config" \
    readarr:local
```

Expected: prints a container ID. `docker ps` shows `readarr-smoke` Up.

- [ ] **Step 4: Wait for `/ping` to return 200**

```bash
for i in $(seq 1 60); do
    if curl -fs http://localhost:18787/ping >/dev/null 2>&1; then
        echo "OK after ${i}s"
        break
    fi
    sleep 1
done
curl -i http://localhost:18787/ping
```

Expected: `OK after Ns` (typically 15–30s on first run, faster on warm). Final `curl -i` prints `HTTP/1.1 200 OK`.

- [ ] **Step 5: Inspect logs and confirm s6 supervision is healthy**

```bash
docker logs readarr-smoke 2>&1 | grep -E "(Bootstrap: Starting|Now listening on|s6-rc)" | head -20
```

Expected: lines showing `[Info] Bootstrap: Starting Readarr` and `[Info] Microsoft.Hosting.Lifetime: Now listening on: http://[::]:8787`. No "s6-rc: fatal" or repeated restart entries.

- [ ] **Step 6: Confirm the config volume was chowned correctly**

```bash
docker exec readarr-smoke ls -la /config | head -10
```

Expected: `/config` and its contents are owned by `abc abc` (the runtime user, mapped to PUID/PGID).

- [ ] **Step 7: Tear down**

```bash
docker stop readarr-smoke && docker rm readarr-smoke
rm -rf .local-readarr-config
```

- [ ] **Step 8: Commit nothing — Task 2 is a verification gate**

If all preceding steps passed, advance to Task 3. If any failed, fix Task 1's files and rerun this task.

---

## Task 3: Author the GitHub Actions workflow

**Files:**
- Create: `.github/workflows/docker.yml`

### Steps

- [ ] **Step 1: Confirm GitHub repo settings allow the workflow**

In a browser, visit `https://github.com/titusjohnson/Readarr/settings/actions` and confirm:
- "Allow all actions and reusable workflows" or equivalent is selected.
- Under "Workflow permissions", "Read and write permissions" is selected (this lets `GITHUB_TOKEN` write to GHCR).

If either is not set, fix and proceed. (No file change for this step — manual prerequisite.)

- [ ] **Step 2: Write `.github/workflows/docker.yml`**

```yaml
name: Build and push dogfooding image

on:
  push:
    branches: [develop]
  workflow_dispatch: {}

permissions:
  contents: read
  packages: write

env:
  IMAGE_NAME: ghcr.io/${{ github.repository_owner }}/readarr

jobs:
  build:
    name: Build, smoke-test, push
    runs-on: ubuntu-latest
    timeout-minutes: 30

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup .NET 6 SDK
        uses: actions/setup-dotnet@v4
        with:
          dotnet-version: 6.0.x

      - name: Cache NuGet packages
        uses: actions/cache@v4
        with:
          path: ~/.nuget/packages
          key: nuget-${{ runner.os }}-${{ hashFiles('**/*.csproj', 'src/Directory.Packages.props') }}
          restore-keys: |
            nuget-${{ runner.os }}-

      - name: Setup Node 20
        uses: actions/setup-node@v4
        with:
          node-version: 20.11.1
          cache: yarn

      - name: Build backend (linux-x64, framework-dependent)
        run: |
          dotnet msbuild -restore src/Readarr.sln \
              -p:Configuration=Release \
              -p:Platform=Posix \
              -p:RuntimeIdentifiers=linux-x64 \
              -p:SelfContained=false \
              -t:PublishAllRids \
              -nologo -v:minimal

      - name: Build frontend
        run: |
          yarn install --frozen-lockfile --network-timeout 600000
          yarn run build --env production

      - name: Stage Docker context
        run: |
          rm -rf docker/context
          mkdir -p docker/context
          cp -R _output/net6.0/linux-x64/publish docker/context/publish
          cp -R _output/UI docker/context/UI

      - name: Set short SHA
        id: sha
        run: echo "short=$(echo ${{ github.sha }} | cut -c1-7)" >> "$GITHUB_OUTPUT"

      - name: Setup Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.repository_owner }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build image (load for smoke test)
        uses: docker/build-push-action@v6
        with:
          context: docker
          load: true
          tags: readarr:ci
          cache-from: type=registry,ref=${{ env.IMAGE_NAME }}:buildcache
          cache-to: type=registry,ref=${{ env.IMAGE_NAME }}:buildcache,mode=max

      - name: Smoke test (boot + /ping returns 200)
        run: |
          set -euo pipefail
          docker run -d --name readarr-smoke \
              -p 18787:8787 \
              -e PUID=1000 -e PGID=1000 -e TZ=UTC \
              readarr:ci
          ok=0
          for i in $(seq 1 60); do
              if curl -fs http://localhost:18787/ping >/dev/null 2>&1; then
                  echo "OK after ${i}s"
                  ok=1
                  break
              fi
              sleep 1
          done
          docker logs readarr-smoke || true
          docker stop readarr-smoke || true
          docker rm readarr-smoke || true
          if [ "$ok" -ne 1 ]; then
              echo "::error::Smoke test failed: /ping did not return 200 within 60s"
              exit 1
          fi

      - name: Push image
        if: github.event_name == 'push' || github.event_name == 'workflow_dispatch'
        uses: docker/build-push-action@v6
        with:
          context: docker
          push: true
          tags: |
            ${{ env.IMAGE_NAME }}:develop
            ${{ env.IMAGE_NAME }}:sha-${{ steps.sha.outputs.short }}
          cache-from: type=registry,ref=${{ env.IMAGE_NAME }}:buildcache
```

- [ ] **Step 3: Validate the YAML locally**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/docker.yml'))" && echo "YAML OK"
```

Expected: `YAML OK`. (Python's PyYAML ships with macOS — if missing, install via `pip3 install pyyaml`.)

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/docker.yml
git commit -m "Add GHA workflow to build and push dogfooding image to GHCR"
```

---

## Task 4: Verify the workflow end-to-end via workflow_dispatch

This task confirms the workflow runs green and produces a pullable image in GHCR before relying on automatic push triggers.

**Files:** none modified.

### Steps

- [ ] **Step 1: Push the develop branch to GitHub**

```bash
git push origin develop
```

Expected: push succeeds. The push itself **will trigger the workflow** (since the `on: push: branches: [develop]` trigger fires). That's fine — let it run as the first real test. If you want to dry-run before letting the auto-trigger fire, push to a side branch first and use `workflow_dispatch` from the Actions UI instead.

- [ ] **Step 2: Open the Actions UI and find the run**

```bash
gh run list --workflow=docker.yml --limit 5
```

Expected: most recent run on `develop` is `queued` or `in_progress`. Note its ID.

- [ ] **Step 3: Watch the run**

```bash
gh run watch <RUN_ID>
```

Expected: each step turns green. Total wall-clock ~10–14 min cold, ~6–8 min with caches warm. The `Smoke test` step's logs should include `OK after Ns` and Readarr's `Now listening on: http://[::]:8787`.

- [ ] **Step 4: Confirm the image landed in GHCR**

```bash
gh api "/users/titusjohnson/packages/container/readarr/versions" --jq '.[0:5] | .[] | {id, name, tags: .metadata.container.tags}'
```

Expected: at least one entry with `tags` containing both `develop` and `sha-<short>` matching `git rev-parse --short HEAD` (7 chars).

- [ ] **Step 5: Pull the image locally to validate registry access**

```bash
gh auth token | docker login ghcr.io -u titusjohnson --password-stdin
docker pull ghcr.io/titusjohnson/readarr:develop
docker images ghcr.io/titusjohnson/readarr
```

Expected: `pull` reports `Status: Downloaded newer image`. `docker images` lists the `develop` tag with a non-zero size (~400–600 MB).

- [ ] **Step 6: Run the GHCR-pulled image and re-verify**

```bash
mkdir -p .ghcr-readarr-config
docker run -d --name readarr-ghcr \
    -p 28787:8787 \
    -e PUID=$(id -u) -e PGID=$(id -g) -e TZ=UTC \
    -v "$(pwd)/.ghcr-readarr-config:/config" \
    ghcr.io/titusjohnson/readarr:develop
for i in $(seq 1 60); do
    curl -fs http://localhost:28787/ping >/dev/null 2>&1 && echo "OK after ${i}s" && break
    sleep 1
done
curl -i http://localhost:28787/ping
docker stop readarr-ghcr && docker rm readarr-ghcr
rm -rf .ghcr-readarr-config
```

Expected: `OK after Ns`, then `HTTP/1.1 200 OK`. Cleanup runs.

- [ ] **Step 7: Commit nothing — Task 4 is a verification gate**

If steps 1–6 passed, the CI loop works end-to-end. If anything failed, fix the workflow file (Task 3), commit, push, and re-run this task.

---

## Task 5: Server operator documentation

**Files:**
- Create: `docs/dogfooding.md`

### Steps

- [ ] **Step 1: Write `docs/dogfooding.md`**

```markdown
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
```

- [ ] **Step 2: Verify the doc renders cleanly**

```bash
# Spot-check there are no broken inline code blocks or stray markup
grep -nE '^```|^#' docs/dogfooding.md | head -40
```

Expected: opens and closes of fenced blocks balance, headings are at sensible levels.

- [ ] **Step 3: Commit**

```bash
git add docs/dogfooding.md
git commit -m "Add dogfooding.md server operator guide"
```

---

## Task 6: First real dogfood run on the server

This task is performed on the home server, not the dev machine. It exercises the complete loop with real config.

**Files:** none in this repo. Modifies the server's `docker-compose.yml`.

### Steps

- [ ] **Step 1: SSH to the server and confirm it's authed to GHCR**

```bash
# On the server
docker pull ghcr.io/titusjohnson/readarr:develop
```

Expected: image pulls. If you get `unauthorized` or `denied`, re-run the `docker login ghcr.io` one-liner from `docs/dogfooding.md`.

- [ ] **Step 2: Append the `readarr` block to the server's `docker-compose.yml`**

Open the file, paste the snippet from `docs/dogfooding.md` step 2, and fill in:
- `PUID`/`PGID` (match the values used by your sonarr/radarr services)
- `TZ`
- `volumes:` paths (a fresh `./readarr-config:/config`, your real books library path, your downloads path)
- `networks:` (match the network your other arr services use)

- [ ] **Step 3: Start Readarr**

```bash
docker compose up -d readarr
docker compose logs -f readarr
```

Expected: log stream shows `Bootstrap: Starting Readarr - ... Version 10.0.0.N`, then ~150 migration entries, then `Now listening on: http://[::]:8787`, then `Application started`.

- [ ] **Step 4: Verify HTTP from the LAN**

```bash
curl -i http://<server-ip>:8787/ping
```

Expected: `HTTP/1.1 200 OK` with no body. Replace `<server-ip>` with the server's LAN address.

- [ ] **Step 5: Confirm UI loads in a browser**

Visit `http://<server-ip>:8787/` from another machine on the LAN. Expected: the Readarr setup/login screen renders.

- [ ] **Step 6: Document the dogfood loop succeeded**

This task has no commit. It's the proof-of-life that the entire pipeline — `git push` → GHA build → GHCR push → server pull → running daemon — works end-to-end. From here forward, "dogfooding a change" is:

```
# On dev machine
git push origin develop
# Wait for workflow at https://github.com/titusjohnson/Readarr/actions

# On server
docker compose pull readarr && docker compose up -d readarr
```

---

## Self-review

**Spec coverage check** (against `2026-05-12-docker-dogfooding-deploy-design.md`):

| Spec requirement | Covered by |
|---|---|
| GHCR private registry | Task 3 step 2 (no public flag), Task 5 (login required) |
| `:develop` and `:sha-<short>` tags | Task 3 step 2 (push step tags) |
| linuxserver.io base image | Task 1 step 3 (Dockerfile FROM) |
| Framework-dependent .NET 6 publish + ASP.NET 6 runtime in image | Task 1 step 3 (Dockerfile installs runtime via dotnet-install.sh + libicu72), Task 3 step 2 (build flag `SelfContained=false`) — see spec amendments A1/A2 |
| s6-overlay service supervision | Task 1 steps 4–9 |
| `/config`, `/books`, `/downloads` volumes | Task 1 step 3 (Dockerfile VOLUME) |
| `PUID`/`PGID` env support | Task 1 step 5 (run script uses abc), Task 2 step 3, Task 5 docs |
| CI verification gate (`/ping` 200 within 30s) | Task 3 step 2 (smoke test uses 60s window — wider than spec for safety; spec allows ≥30s) |
| Push trigger on develop | Task 3 step 2 (on.push.branches) |
| `workflow_dispatch` for manual runs | Task 3 step 2 (on.workflow_dispatch) |
| amd64-only build | Task 3 step 2 (no platforms flag → defaults to runner arch which is amd64) |
| Manual server-side pull (no Watchtower) | Task 5 docs, Task 6 |
| Compose snippet for the user's stack | Task 5 docs |
| Rollback guidance | Task 5 docs |

**Placeholder scan:** None. All file contents and commands are written out explicitly.

**Type consistency:** s6 service names (`svc-readarr`, `init-readarr-config`) are spelled identically across Tasks 1, 2, and the dependency markers. Tag names (`:develop`, `:sha-<short>`) match between Task 3 push step and Task 5 docs.

**Open assumption baked into the plan:** The first push to `develop` after committing Task 3 will auto-trigger the workflow. Task 4 step 1 notes this and gives the user the option to push to a side branch first. If that's not acceptable, change Task 3's trigger to `workflow_dispatch` only for the first run and add `push: branches: [develop]` later — but for a single-committer fork in revival mode this is appropriate friction.
