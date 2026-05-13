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
