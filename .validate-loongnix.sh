#!/usr/bin/env bash
set -Eeuo pipefail

epoch="$(TZ=UTC date --date "$TIMESTAMP" +%s)"
serial="$(TZ=UTC date --date "@$epoch" +%Y%m%d)"

buildArgs=()
if [ "$SUITE" = 'eol' ]; then
	buildArgs+=( '--eol' )
	SUITE="$CODENAME"
fi

buildArgs+=( validate "$SUITE")

checkFile="validate/$serial/${ARCH:-amd64}/${CODENAME:-$SUITE}/rootfs.tar.xz"
mkdir -p validate

set -x

./scripts/debuerreotype-version
./docker-run.sh --pull ./examples/loongnix.sh "${buildArgs[@]}"

real="$(sha256sum "$checkFile" | cut -d' ' -f1)"
[ -z "$SHA256" ] || [ "$SHA256" = "$real" ]

mkdir -pv ./artifacts
cp -rfv validate/$serial/${ARCH:-amd64}/ ./artifacts/
