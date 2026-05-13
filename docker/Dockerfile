# syntax=docker/dockerfile:1.7
ARG BASE_IMAGE=lscr.io/linuxserver/baseimage-debian:bookworm
FROM ${BASE_IMAGE}

LABEL org.opencontainers.image.source="https://github.com/titusjohnson/Readarr"
LABEL org.opencontainers.image.description="Readarr (revival fork) — dogfooding image"
LABEL org.opencontainers.image.licenses="GPL-3.0"

# Self-contained .NET 6 publish output, built on the runner (or via build-local.sh).
# Layout in build context: docker/context/publish/ for the backend, docker/context/UI/ for the frontend.
COPY context/publish/ /app/readarr/bin/
COPY context/UI/ /app/readarr/bin/UI/
COPY root/ /

RUN chmod +x /app/readarr/bin/Readarr && \
    find /etc/s6-overlay/s6-rc.d -type f -name run -exec chmod +x {} + && \
    find /etc/s6-overlay/scripts -type f -exec chmod +x {} +

EXPOSE 8787

VOLUME ["/config", "/books", "/downloads"]
