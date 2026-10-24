# Chantey

The engine that Catboat Hosts run. Chantey is built from sing-box's
source with a small patch series: through the SSM API, users are added, changed and removed on a
running inbound of every type a Host serves, with no restart, and removed
users are shut out at once. The Catboat Agent installs it from a signed
manifest and drives it as it drives the official sing-box.

Licensed under GPL-3.0-or-later; see `LICENSE` and `NOTICE`. Chantey is
not sing-box and is not associated with its authors. Contributions need a
DCO sign-off; see the `packet-boats/.github` repository for the
contribution guide and the security policy. Please report security
problems privately, not in an issue.

## What the patches change

| Repository | Change |
| --- | --- |
| sing-box | VLESS, Hysteria2, TUIC, VMess, Trojan, Hysteria, AnyTLS, Snell, SOCKS, HTTP, mixed and Naive inbounds take user updates from the SSM API while they run. An inbound bound to the SSM API with no users refuses every client. The SSM API rolls back a change the inbound refuses, and refuses empty credentials. The program calls itself chantey, and `chantey version` names the sing-box release it is built from. |
| sing-quic | Hysteria2, TUIC and Hysteria update users while they run and close a removed user's sessions. |
| sing-vmess | VMess updates users while it runs. VLESS Vision guards its TLS filter state with a lock, which fixes a data race in the upstream module. |
| sing-snell | Snell v5 and v6 update users while they run, also to an empty list. |
| sing-anytls | AnyTLS updates users while it runs and closes a removed user's sessions; a stream reads its close error atomically. |

The SSM API carries one credential string per user, which each inbound
reads its own way:

| Inbound | Credential |
| --- | --- |
| VLESS | `uuid`, or `uuid:xtls-rprx-vision` |
| TUIC | `uuid:password` |
| VMess | `uuid` (alterId 0 only) |
| all others | the password or key |

SOCKS, HTTP, mixed and Naive take the SSM user name as the username.
Re-adding a user starts its counters from zero, and a restart clears users
and counters, so the Agent adds its users again after every start.

## Build

```sh
./build.sh            # chantey for linux/amd64 and linux/arm64, into dist/
./build.sh -t         # the same, after the tests of every patched package
./build.sh -s         # the same, with the source archive
./build.sh -a amd64   # one architecture
```

It needs git, Go 1.21 or later, and access to GitHub and the Go module
proxy. Go fetches and runs the release named in
`patches/<base>/toolchain`, the newest patch release of the Go version
upstream built sing-box with. For each
repository in `patches/<base>/bases.txt` the script clones the upstream
repository at the pinned commit and applies that repository's patches.
sing-box's other modules are vendored, keeping only the packages the
linux/amd64 and linux/arm64 builds use, and sing-box then builds from the
patched modules and `vendor/` with CGO off, so the binary is static and
runs on glibc and musl systems alike. Each
architecture gets `dist/chantey-<version>-linux-<arch>.tar.gz` with
`chantey`, `LICENSE` and `NOTICE`, and `dist/SHA256SUMS` lists them. The
build leaves out timestamps and paths, so the same inputs give the same
archives.

`-s` also writes `dist/chantey-<version>-src.tar.gz`, the complete source
the binaries are built from: this script, the patches, and the patched
sources with `vendor/`. Unpacked, it builds the same archives again with
no access to GitHub or the module proxy:

```sh
tar -xzf chantey-<version>-src.tar.gz && cd chantey-<version>-src
./build.sh -l         # builds from the sources in work/<base>/
```

Go still fetches the release named in `patches/<base>/toolchain` unless
it is that release already. CI checks on every change that the source
archive rebuilds the same archives.

## Layout

| Path | What |
| --- | --- |
| `patches/<base>/bases.txt` | the upstream repositories, their pinned commits, and the modules they stand in for |
| `patches/<base>/version` | the Chantey version built from this base, `<base>-chantey.<n>` |
| `patches/<base>/toolchain` | the Go release the build runs |
| `patches/<base>/<repository>/` | the patch series for that repository, in `git format-patch` form |
| `build.sh` | clone, patch, test, vendor, build, and pack the source |

A new upstream release gets a directory of its own, with the series
rebased onto it; `build.sh` builds the newest one unless `-b` names
another. A change to the patches or the Go release of a released base
raises `<n>`.

## New sing-box releases

```sh
./upstream.sh          # a set for sing-box's newest stable release, built and tested
./upstream.sh 1.14.5   # a set for that release
./upstream.sh -n       # only print the release it would prepare
```

`upstream.sh` copies the newest patch set to `patches/<version>`, pins
`bases.txt` to the release and to the module versions its `go.mod` names,
takes the newest patch release of the Go version the official build was
made with, and runs `./build.sh -t -a amd64` on it. It needs jq besides
what `build.sh` needs. When a patch does not apply or a test fails, the
series needs rebasing by hand (see below).

## Working on a patch

```sh
./build.sh -a amd64                      # leaves the patched sources in work/<base>/
cd work/1.14.4/sing-box && git add -A && git commit -m wip   # then edit, test and commit
git format-patch --zero-commit -N --no-signature -o ../../../patches/1.14.4/sing-box c005f353..HEAD
```

`build.sh` applies the patches without committing, so commit them in the
work tree before changing them, and write the series back with
`git format-patch` from the pinned commit. Keep each patch to one change
and its commit message in the patch.

## Releases

Pushing a tag `v<version>`, with the version in `patches/<base>/version`,
runs CI as for any change and then publishes both archives, the source
archive and `SHA256SUMS` as a GitHub release of that tag. They are
marked as pre-releases until Catboat 1.0. CI signs nothing: the
Catboat Agent installs an engine only when a signed manifest lists its
SHA-256, and that manifest is signed offline from `SHA256SUMS`.

## Distributing

Whoever receives a Chantey binary may also receive its corresponding
source under the GPL: the source archive of the same version, which each
release carries and which holds it complete, or this repository at the
commit that built it, which pins every upstream source by commit.
