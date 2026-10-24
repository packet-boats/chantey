#!/usr/bin/env bash
# Copyright 2026 Packet Boats
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds Chantey from the upstream sources and the patches here:
#
#   ./build.sh [-b base] [-a "amd64 arm64"] [-o dist] [-t]
#
# For each repository in patches/<base>/bases.txt it clones the upstream
# repository, checks out the pinned commit and applies that repository's
# patches. sing-box then builds against the patched modules, with CGO
# off, so the binary is static. Each architecture gets
# <out>/chantey-<version>-linux-<arch>.tar.gz, holding chantey, LICENSE
# and NOTICE, and its SHA-256 goes to <out>/SHA256SUMS. -t runs the tests of
# every patched package first. Go runs as the release named in
# patches/<base>/toolchain, so the same inputs give the same archives.
# The base defaults to the newest directory in patches/; the sources go
# to work/<base>, which a new build replaces.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
BASE='' ARCHES="amd64 arm64" OUT=$HERE/dist TEST=''
while getopts b:a:o:t opt; do
	case $opt in
	b) BASE=$OPTARG ;;
	a) ARCHES=$OPTARG ;;
	o) OUT=$OPTARG ;;
	t) TEST=1 ;;
	*) exit 2 ;;
	esac
done
[ -n "$BASE" ] || BASE=$(cd "$HERE/patches" && printf '%s\n' */ | tr -d / | sort -V | tail -1)
P=$HERE/patches/$BASE
[ -f "$P/bases.txt" ] || { echo "no patches/$BASE/bases.txt" >&2; exit 1; }
VERSION=$(cat "$P/version")
GOTOOLCHAIN=$(cat "$P/toolchain")
export GOTOOLCHAIN
W=$HERE/work/$BASE
rm -rf "$W"
mkdir -p "$W" "$OUT"

replaces=()
while read -r dir repo commit module; do
	case $dir in "" | "#"*) continue ;; esac
	echo "$dir: $repo at ${commit:0:12}"
	git clone -q --filter=blob:none --no-checkout "$repo" "$W/$dir"
	git -C "$W/$dir" -c advice.detachedHead=false checkout -q "$commit"
	[ "$(git -C "$W/$dir" rev-parse HEAD)" = "$commit" ] || { echo "$dir: not at $commit" >&2; exit 1; }
	for p in "$P/$dir"/*.patch; do
		[ -e "$p" ] || continue
		git -C "$W/$dir" apply --whitespace=nowarn "$p" || { echo "$dir: $(basename "$p") does not apply" >&2; exit 1; }
	done
	[ "$module" = - ] || replaces+=("-replace=$module=../$dir")
done <"$P/bases.txt"
SB=$W/sing-box
[ ${#replaces[@]} -eq 0 ] || (cd "$SB" && go mod edit "${replaces[@]}")

if [ -n "$TEST" ]; then
	while read -r dir _ commit _; do
		case $dir in "" | "#"*) continue ;; esac
		pkgs=$(git -C "$W/$dir" diff --name-only "$commit" -- '*.go' | xargs -r -n1 dirname | sort -u | sed 's#^#./#' | tr '\n' ' ')
		[ -n "$pkgs" ] || continue
		echo "$dir: testing $pkgs"
		# Upstream's VLESS Vision reads TLS internals through unsafe
		# pointers on purpose, so vet's unsafeptr check is left out.
		# shellcheck disable=SC2086
		(cd "$W/$dir" && go vet -unsafeptr=false $pkgs && go test -count=1 $pkgs)
	done <"$P/bases.txt"
fi

TAGS=$(cat "$SB/release/DEFAULT_BUILD_TAGS_OTHERS")
LDFLAGS="$(cat "$SB/release/LDFLAGS") -s -w -buildid= -X github.com/sagernet/sing-box/constant.Version=$VERSION"
for arch in $ARCHES; do
	name=chantey-$VERSION-linux-$arch
	rm -rf "${W:?}/$name"
	mkdir -p "$W/$name"
	echo "building $name"
	(cd "$SB" && CGO_ENABLED=0 GOOS=linux GOARCH=$arch go build -trimpath -buildvcs=false -tags "$TAGS" \
		-ldflags "$LDFLAGS" -o "$W/$name/chantey" ./cmd/sing-box)
	cp "$HERE/LICENSE" "$HERE/NOTICE" "$W/$name/"
	tar -C "$W" --owner=0 --group=0 --numeric-owner --mtime=@0 --sort=name -cf - "$name" | gzip -n >"$OUT/$name.tar.gz"
	(cd "$OUT" && { grep -v " $name.tar.gz\$" SHA256SUMS 2>/dev/null || true; } && sha256sum "$name.tar.gz") >"$OUT/SHA256SUMS.new"
	mv "$OUT/SHA256SUMS.new" "$OUT/SHA256SUMS"
done
cat "$OUT/SHA256SUMS"
