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
