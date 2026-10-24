#!/usr/bin/env bash
# Copyright 2026 Packet Boats
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Builds Chantey from the upstream sources and the patches here:
#
#   ./build.sh [-b base] [-a "amd64 arm64"] [-o dist] [-t] [-s | -l]
#
# For each repository in patches/<base>/bases.txt it clones the upstream
# repository, checks out the pinned commit and applies that repository's
# patches. sing-box's other modules are vendored, keeping only the
# packages that the linux/amd64 and linux/arm64 builds (and any other
# architecture -a names) use. sing-box then builds from the patched
# modules and vendor/ with CGO off, so the binary is static. Each
# architecture gets <out>/chantey-<version>-linux-<arch>.tar.gz, holding
# chantey, LICENSE and NOTICE, and its SHA-256 goes to <out>/SHA256SUMS.
# -t runs the tests of every patched package first. -s also packs the
# complete source the binaries are built from as
# <out>/chantey-<version>-src.tar.gz: this script, the patches and the
# patched sources with vendor/. -l builds from the sources already in
# work/<base>, as an unpacked source archive holds them, instead of
# cloning them. Go runs as the release named in patches/<base>/toolchain,
# so the same inputs give the same archives. The base defaults to the
# newest directory in patches/; the sources go to work/<base>, which a new
# build without -l replaces.
set -euo pipefail
export LC_ALL=C

HERE=$(cd "$(dirname "$0")" && pwd)
BASE='' ARCHES="amd64 arm64" OUT=$HERE/dist TEST='' SRC='' LOCAL=''
while getopts b:a:o:tsl opt; do
	case $opt in
	b) BASE=$OPTARG ;;
	a) ARCHES=$OPTARG ;;
	o) OUT=$OPTARG ;;
	t) TEST=1 ;;
	s) SRC=1 ;;
	l) LOCAL=1 ;;
	*) exit 2 ;;
	esac
done
[ -z "$LOCAL" ] || [ -z "$TEST$SRC" ] || { echo "-l takes neither -t nor -s" >&2; exit 2; }
[ -n "$BASE" ] || BASE=$(cd "$HERE/patches" && printf '%s\n' */ | tr -d / | sort -V | tail -1)
P=$HERE/patches/$BASE
[ -f "$P/bases.txt" ] || { echo "no patches/$BASE/bases.txt" >&2; exit 1; }
VERSION=$(cat "$P/version")
GOTOOLCHAIN=$(cat "$P/toolchain")
export GOTOOLCHAIN
W=$HERE/work/$BASE
SB=$W/sing-box
mkdir -p "$OUT"

# sum <archive> puts the archive's SHA-256 in place of its old line in
# SHA256SUMS.
sum() {
	(cd "$OUT" && { grep -v " $1\$" SHA256SUMS 2>/dev/null || true; } && sha256sum "$1") >"$OUT/SHA256SUMS.new"
	mv "$OUT/SHA256SUMS.new" "$OUT/SHA256SUMS"
}

if [ -n "$LOCAL" ]; then
	[ -f "$SB/vendor/modules.txt" ] || { echo "no sources in work/$BASE" >&2; exit 1; }
else
	rm -rf "$W"
	mkdir -p "$W"
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
	[ ${#replaces[@]} -eq 0 ] || (cd "$SB" && go mod edit "${replaces[@]}")
fi

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

if [ -z "$LOCAL" ]; then
	# go mod vendor copies the packages of every platform and the files
	# they embed, among them prebuilt libraries this build never links.
	# Only the files of the packages a supported build imports, the files
	# those embed, modules.txt and the licence files on the way to them
	# stay.
	(cd "$SB" && go mod vendor)
	# shellcheck disable=SC2086
	for arch in $(printf '%s\n' amd64 arm64 $ARCHES | sort -u); do
		(cd "$SB" && CGO_ENABLED=0 GOOS=linux GOARCH=$arch go list -mod=vendor -deps -tags "$TAGS" \
			-f '{{if and .Module (not .Module.Main)}}{{.Dir}}{{range .EmbedFiles}}{{"\n"}}{{$.Dir}}/{{.}}{{end}}{{end}}' \
			./cmd/sing-box)
	done | sort -u >"$W/used"
	find "$SB/vendor" -type f | awk -v vendor="$SB/vendor" '
		NR == FNR {
			keep[$0] = 1
			for (d = $0; d != vendor && index(d, "/"); sub(/\/[^\/]*$/, "", d)) on_way[d] = 1
			next
		}
		{ d = $0; sub(/\/[^\/]*$/, "", d); name = substr($0, length(d) + 2) }
		$0 in keep || d in keep || $0 == vendor "/modules.txt" { next }
		d in on_way && name ~ /^(LICENSE|LICENCE|COPYING|NOTICE|PATENTS|AUTHORS|CONTRIBUTORS)/ { next }
		{ print }
	' "$W/used" - | tr '\n' '\0' | xargs -0 -r rm -f --
	find "$SB/vendor" -type d -empty -delete
	rm "$W/used"
fi
if [ -n "$SRC" ]; then
	name=chantey-$VERSION-src
	echo "packing $name"
	tar -C "$HERE" --exclude=.git --owner=0 --group=0 --numeric-owner --mtime=@0 --sort=name \
		--transform "s,^,$name/,S" -cf - LICENSE NOTICE README.md build.sh "patches/$BASE" "work/$BASE" |
		gzip -n >"$OUT/$name.tar.gz"
	sum "$name.tar.gz"
fi

for arch in $ARCHES; do
	name=chantey-$VERSION-linux-$arch
	rm -rf "${W:?}/$name"
	mkdir -p "$W/$name"
	echo "building $name"
	(cd "$SB" && CGO_ENABLED=0 GOOS=linux GOARCH=$arch go build -mod=vendor -trimpath -buildvcs=false -tags "$TAGS" \
		-ldflags "$LDFLAGS" -o "$W/$name/chantey" ./cmd/sing-box)
	cp "$HERE/LICENSE" "$HERE/NOTICE" "$W/$name/"
	tar -C "$W" --owner=0 --group=0 --numeric-owner --mtime=@0 --sort=name -cf - "$name" | gzip -n >"$OUT/$name.tar.gz"
	sum "$name.tar.gz"
	rm -rf "${W:?}/$name"
done
cat "$OUT/SHA256SUMS"
