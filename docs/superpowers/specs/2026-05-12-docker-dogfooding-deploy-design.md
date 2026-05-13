# Docker Dogfooding Deploy — Design

**Date:** 2026-05-12
**Status:** Approved — amended 2026-05-12 during Task 2 smoke test (see "Amendments" below)

## Goal

Stand up a tight `git push` → running container loop so the fork owner can dogfood Readarr changes on a personal home server (x86_64 / Ubuntu 18.04 / Docker 24) alongside an existing Sonarr + Radarr stack. The loop should let the user verify their fork against real metadata-source, indexer, and download-client behavior — the conditions that ultimately killed upstream Readarr.

## Non-goals

- Public release / shipping to other users — image stays private on GHCR until the fork is "looking good to go public" (user's words).
- Multi-arch support (no `linux/arm64`) — defer until there's an actual ARM target.
- Versioned release tagging (`v0.4.20`, `:latest`) — that's a separate, deliberate motion and will be designed when needed.
- Automated server-side deploy (no Watchtower, no SSH-driven webhook from CI). User pulls when they decide to.
- Migration from any existing Readarr install on the server — confirmed greenfield.
- Cross-environment build from the Mac to the server. CI is the only path images take to the server.

## Decisions and rationale

| Decision | Choice | Rationale |
|---|---|---|
| Trigger | Push to `develop` | Tightest feedback loop for a single-committer revival fork |
| Image registry | GHCR (`ghcr.io/titusjohnson/readarr`) | Free, auths with the workflow's built-in `GITHUB_TOKEN`, private-by-default supports the staged rollout |
| Image visibility | **Private** | User isn't ready to advertise the fork; flip to public later |
| Image style | linuxserver.io-base (s6-overlay, `PUID`/`PGID`, `/config` + `/books` volumes) | Drops into the user's existing *arr compose stack with matching conventions |
| Base image | `lscr.io/linuxserver/baseimage-debian:bookworm` | Readarr historically had issues on musl libc (alpine); size penalty doesn't matter on a home server |
| Architecture | `linux/amd64` only | Matches the server precisely, keeps CI minutes cheap |
| Tags per build | `:develop` (rolling) and `:sha-<short>` (immutable) | Convenience handle + pin point for stability |
| Update path on server | Manual `docker compose pull readarr && docker compose up -d readarr` | Watchtower auto-updates mid-debug is the wrong default for dogfooding |
| CI verification | Run the built image, curl `/ping`, fail if not 200 within 30s | Cheap "boots and binds" gate before image becomes pullable |
| .NET target | `net6.0` (matches current source) | Modernization to .NET 8 is a separate, larger initiative |

## Architecture

```
your Mac                        GitHub Actions                     Ubuntu 18 server
  │                              ─────────────────                   ────────────────
  │ git push develop ───────►   build backend (-p:RuntimeIdentifiers=linux-x64)
  │                              build frontend (yarn build --env production)
  │                              docker buildx build (linuxserver base)
  │                              run image + curl /ping (must return 200)
  │                              push to ghcr.io/titusjohnson/readarr
  │                                   tagged :develop and :sha-<short>           │
  │                                                                              ▼
  │                                                          docker compose pull readarr
  │                                                          docker compose up -d readarr
  │                                                          ↓
  │                                                          readarr container on :8787
  │                                                          shares network with sonarr,
  │                                                          radarr, qbittorrent, etc.
```

## Repo changes

All changes live in `titusjohnson/Readarr` (the fork). Nothing upstream.

### `docker/Dockerfile`

Multi-stage:

Single-stage runtime image. We build the backend and frontend on the GitHub Actions runner (not inside Docker) and treat the Dockerfile as a pure packaging step. The build uses **self-contained publish** (`-p:SelfContained=true -p:RuntimeIdentifier=linux-x64`) so the image does not need a separate .NET 6 runtime install — this both keeps the image lean and insulates us from .NET 6's EOL status on Microsoft's apt repos.

Runtime stage based on `lscr.io/linuxserver/baseimage-debian:bookworm`:

- `COPY` the published `linux-x64` self-contained output into `/app/readarr/bin`.
- `COPY` the built UI (`_output/UI/`) into `/app/readarr/bin/UI` (Readarr expects UI as a sibling of its binary).
- `COPY` the s6 service definitions from `docker/root/` into `/`.
- `EXPOSE 8787`.
- Volume hints: `/config`, `/books`, `/downloads`.
- `chmod +x` on the `Readarr` entrypoint and any s6 `run` scripts.

### `docker/root/etc/s6-overlay/s6-rc.d/svc-readarr/`

- `type` — file containing `longrun`.
- `run` — shell script that execs `/app/readarr/bin/Readarr -nobrowser -data=/config` as the resolved PUID/PGID user (LSIO base provides the helper).
- Add `svc-readarr` to the appropriate `s6-rc.d/user/contents.d/` so it starts at boot.

(Exact files cribbed and adapted from the LSIO Sonarr Dockerfile / s6 layout — same template.)

### `.github/workflows/docker.yml`

Single workflow, triggered on `push` to `develop`. Steps:

1. Checkout (`actions/checkout@v4`).
2. Setup .NET 6 SDK (`actions/setup-dotnet@v4` with `dotnet-version: 6.0.x`).
3. Cache NuGet (`actions/cache@v4` keyed on `**/*.csproj`).
4. Setup Node 20 + yarn (`actions/setup-node@v4` with `cache: yarn`).
5. Run backend build: `dotnet msbuild -restore src/Readarr.sln -p:Configuration=Release -p:Platform=Posix -p:RuntimeIdentifiers=linux-x64 -p:SelfContained=true -t:PublishAllRids`.
6. Run frontend build: `yarn install --frozen-lockfile --network-timeout 600000` then `yarn build --env production`.
7. Stage artifacts into a `docker/context/` directory (`_output/net6.0/linux-x64/publish/` + `_output/UI/`).
8. Setup buildx (`docker/setup-buildx-action@v3`).
9. Login to GHCR (`docker/login-action@v3` with `GITHUB_TOKEN`).
10. **Build the image with `--load`** (`docker/build-push-action@v6` with `load: true`, no `push`) — this lands the image in the runner's local Docker daemon under a temporary tag. Uses `cache-from`/`cache-to` against the GHCR registry cache.
11. **Smoke-test the loaded image:** `docker run -d -p 8787:8787 ... <temp-tag>`, loop curling `http://localhost:8787/ping` with a 30s deadline. Fail the workflow on timeout. Stop and remove the container.
12. **Push** with a second `docker/build-push-action@v6` invocation (`push: true`, no `load`) tagging `ghcr.io/titusjohnson/readarr:develop` and `ghcr.io/titusjohnson/readarr:sha-<short-sha>`. The registry cache from step 10 makes this near-instant — same layers, just tagged and pushed.

### `docs/dogfooding.md`

Server operator documentation:

- Compose snippet (the service block shown below) ready to paste into the user's existing `docker-compose.yml`.
- GHCR auth one-liner for the server: `echo $PAT | docker login ghcr.io -u titusjohnson --password-stdin` (with a personal access token scoped to `read:packages` only — instructions to create one).
- Update commands: `docker compose pull readarr && docker compose up -d readarr` (plus the variant pinning by `sha-<short>` for stability).
- Rollback: bump compose to the previous `sha-<short>` tag, pull, up.
- Where logs live: `docker logs readarr`, plus the in-container `/config/logs/` directory.
- Troubleshooting: HTTP `/ping` smoke check, "first-run takes a few minutes for DB migrations".

## Compose service shape (user adds to their stack)

```yaml
readarr:
  image: ghcr.io/titusjohnson/readarr:develop
  container_name: readarr
  environment:
    - PUID=<user-id>
    - PGID=<group-id>
    - TZ=<their-tz>
  volumes:
    - ./readarr-config:/config
    - /path/to/books:/books
    - /path/to/downloads:/downloads
  ports:
    - "8787:8787"
  restart: unless-stopped
  networks:
    - <existing-arr-network>
```

## CI verification contract

The workflow must fail (and not push) if:

- Backend build produces any compiler `error CS####`.
- Frontend build exits non-zero or webpack emits an error (warnings tolerated).
- The smoke-test container's `/ping` does not return 200 within 30s.

The workflow may succeed (push the image) even if:

- MSB3026 file-copy retry warnings appear.
- Sentry-CLI "not fully configured" warnings appear (no `SENTRY_AUTH_TOKEN` set).
- Frontend peer-dep warnings appear (existing modernization debt).

## Image-size and CI-cost budget

- Target image size: < 600 MB compressed. (LSIO bookworm base is ~150 MB; self-contained .NET 6 publish for Readarr.Core + deps is ~250–300 MB.) Not a hard fail criterion; tracked.
- Target CI wall-clock: < 8 min per build with caches warm. ~12 min on a cold cache.
- Free-tier minute usage: ~2000 min/month available for private repos; at 8 min/build that's 250+ pushes/month before the budget pinches. Tracked, no action needed yet.

## Risks and mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| LSIO base updates change s6 conventions | Low | Medium | Pin base by digest if it bites |
| .NET 6 EOL — runtime install fails | Low (still installable as of 2026-05) | High | Self-contained publish; we don't depend on `apt` finding the runtime at image-build time |
| GHCR rate limits or outages | Low | Medium | Server-side pulls are infrequent; manual workflow |
| Careless commit lands on server | Medium (single user, no review) | Low–Medium | User pulls deliberately; can pin to `sha-<short>` for stability |
| First-run DB migrations slow | Low | Low | `/ping` smoke test waits 30s — enough for cold-start migrations on the small test data dir; first real-server run also tolerated |
| `Readarr -data=/config` permissions wrong | Medium | Medium | LSIO base's PUID/PGID handling sets ownership at start; verify via smoke test in CI |

## Follow-ups (not in this design's scope)

- Add `linux/arm64` builds.
- Add release-tag-triggered builds with `:vX.Y.Z` and `:latest` tags.
- Add automated server-side deploy (SSH from CI, or a webhook the server polls).
- Flip the GHCR package to public.
- Modernize to .NET 8 (and revisit the Dockerfile then — Microsoft's apt repo serves .NET 8 cleanly).
- Multi-stage Dockerfile that builds inside the image (only worth it if we want reproducible local builds without local toolchain).

## Open assumptions to confirm with user during review

- The user's existing compose stack is in a single `docker-compose.yml` they'd append to (rather than per-service compose files). If it's split, the docs need adjusting. **Confirmed during brainstorming review.**
- The user is OK creating a PAT scoped to `read:packages` for the server. If not, we'd need an alternative auth mechanism. **Confirmed during brainstorming review (server already authed).**

## Amendments (post-approval)

### A1 — 2026-05-12 — Switch from self-contained to framework-dependent publish

**Surfaced by:** Task 2 smoke test failure.

**What changed:** The original design chose `SelfContained=true` for the .NET publish to avoid needing a runtime install in the image. In practice, self-contained publish has a known bug for this codebase: the .NET 6 runtime pack overwrites NuGet's `Microsoft.Extensions.DependencyInjection.Abstractions` 7.0.0 with the framework's 6.0.0 version during publish, causing assembly-version mismatches at startup. Readarr crashes with `System.IO.FileLoadException: ... Version=7.0.0.0 ... manifest definition does not match`.

**New approach:** Use framework-dependent publish (`SelfContained=false`) and install the ASP.NET Core 6 runtime inside the image. This is the configuration used by upstream Readarr, linuxserver/io, and hotio — proven to work.

**Implication:** The original design's risk row about ".NET 6 EOL — runtime install fails" came true. Microsoft has removed `aspnetcore-runtime-6.0` from the Debian 12 apt repo. The mitigation: install via `dotnet-install.sh` from `https://dot.net/v1/dotnet-install.sh`, which fetches binaries from `builds.dotnet.microsoft.com` — Microsoft's documented path for EOL versions. Binaries remain hosted there indefinitely.

**Affects:**
- `docker/Dockerfile` — adds the dotnet-install.sh runtime install step
- `docker/build-local.sh` — `-p:SelfContained=false` (not `=true`)
- `.github/workflows/docker.yml` (Task 3) — same flag change

### A2 — 2026-05-12 — Add libicu72 to runtime image

**Surfaced by:** Task 2 smoke test failure.

**What changed:** Debian-bookworm base ships without `libicu`. .NET 6 requires it for globalization. Readarr ships translations (Weblate-managed), so invariant-mode is not an acceptable workaround.

**New approach:** Install `libicu72` via apt in the Dockerfile.

**Affects:** `docker/Dockerfile` only.
