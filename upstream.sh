#!/usr/bin/env bash
# Copyright 2026 Packet Boats
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Prepares a patch set for a new sing-box release from the newest one here,
# then builds and tests it:
#
#   ./upstream.sh [-n] [version]
#
# With no version it takes sing-box's newest stable release, and stops,
# printing nothing, when patches/ already has a set for that release or a
# newer one. -n prints the version it would prepare and stops. Otherwise it
# copies the newest set to patches/<version> and pins bases.txt to the
# release's commit and to the commits of the module versions the release's
# go.mod names. The toolchain is the newest patch release of the Go version
# the official build was made with, and the build is <version>-chantey.1.
# Then ./build.sh -t -a amd64 applies the patches, runs the tests of every
# patched package and builds.
#
# Exit status: 0 when the patches apply and the tests pass, 1 when they do
# not or the set cannot be prepared, 4 when the release has no official
# linux/amd64 build yet.
set -euo pipefail
export LC_ALL=C

HERE=$(cd "$(dirname "$0")" && pwd)
UPSTREAM=https://github.com/SagerNet/sing-box.git
DRY=''
while getopts n opt; do
	case $opt in
	n) DRY=1 ;;
	*) exit 2 ;;
	esac
done
shift $((OPTIND - 1))

OLD=$(cd "$HERE/patches" && printf '%s\n' */ | tr -d / | sort -V | tail -1)
if [ $# -gt 0 ]; then
	NEW=$1
else
	NEW=$(git ls-remote --tags --refs "$UPSTREAM" 'v*' | sed -n 's#.*refs/tags/v\([0-9]*\.[0-9]*\.[0-9]*\)$#\1#p' | sort -V | tail -1)
	[ -n "$NEW" ] || { echo "no stable sing-box release found" >&2; exit 1; }
	[ "$(printf '%s\n' "$OLD" "$NEW" | sort -V | tail -1)" != "$OLD" ] || exit 0
fi
echo "$NEW" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' || { echo "not a sing-box version: $NEW" >&2; exit 1; }
[ -z "$DRY" ] || { echo "$NEW"; exit 0; }
P=$HERE/patches/$NEW
[ ! -e "$P" ] || { echo "patches/$NEW exists already" >&2; exit 1; }
echo "preparing patches/$NEW from patches/$OLD"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# The Go version of the official build, from the binary itself.
url=https://github.com/SagerNet/sing-box/releases/download/v$NEW/sing-box-$NEW-linux-amd64.tar.gz
if ! curl -fsSL -o "$T/official.tar.gz" "$url"; then
	echo "sing-box $NEW has no official linux/amd64 build yet" >&2
	exit 4
fi
tar -xzf "$T/official.tar.gz" -C "$T"
built=$(go version "$T/sing-box-$NEW-linux-amd64/sing-box" | awk '{print $2}')
minor=$(echo "$built" | sed -n 's/^\(go[0-9]*\.[0-9]*\).*/\1/p')
[ -n "$minor" ] || { echo "cannot read the Go version of the official build: $built" >&2; exit 1; }
toolchain=$(curl -fsSL 'https://go.dev/dl/?mode=json&include=all' | jq -r '.[] | select(.stable) | .version' |
	grep -E "^$minor(\.[0-9]+)?\$" | sort -V | tail -1)
[ -n "$toolchain" ] || { echo "no stable Go release for $minor" >&2; exit 1; }
echo "toolchain: $toolchain (the official build used $built)"

# The release's commit and its go.mod.
git clone -q --filter=blob:none --no-checkout "$UPSTREAM" "$T/sing-box"
commit=$(git -C "$T/sing-box" rev-parse --verify "refs/tags/v$NEW^{commit}")
git -C "$T/sing-box" show "$commit:go.mod" >"$T/go.mod"

mkdir -p "$P"
cp -R "$HERE/patches/$OLD"/. "$P"/
echo "$toolchain" >"$P/toolchain"
echo "$NEW-chantey.1" >"$P/version"
# edit <sed expression>: edits the new bases.txt in place.
edit() { sed "$1" "$P/bases.txt" >"$T/bases.txt" && mv "$T/bases.txt" "$P/bases.txt"; }
edit "s/sing-box v$OLD /sing-box v$NEW /"
while read -r dir repo old module; do
	case $dir in "" | "#"*) continue ;; esac
	if [ "$module" = - ]; then
		edit "s/$old/$commit/"
		echo "$dir: v$NEW, ${commit:0:12}"
		continue
	fi
	ver=$(go mod edit -json "$T/go.mod" | jq -r --arg m "$module" '.Require[]? | select(.Path == $m) | .Version')
	if [ -z "$ver" ]; then
		echo "$dir: sing-box $NEW's go.mod has no $module; bases.txt needs a hand" >&2
		exit 1
	fi
	git clone -q --filter=blob:none --no-checkout "$repo" "$T/$dir"
	# A pseudo-version ends in the commit's first 12 hex digits; any other
	# version is a tag.
	ref=$(echo "$ver" | sed -n 's/.*[0-9]\{14\}-\([0-9a-f]\{12\}\)$/\1/p')
	[ -n "$ref" ] || ref=refs/tags/$ver
	new=$(git -C "$T/$dir" rev-parse --verify "$ref^{commit}") || { echo "$dir: no commit for $ver" >&2; exit 1; }
	edit "s/$old/$new/"
	echo "$dir: $ver, ${new:0:12}"
done <"$HERE/patches/$OLD/bases.txt"

"$HERE/build.sh" -b "$NEW" -t -a amd64
