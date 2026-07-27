# CLAUDE.md — project context for Appbox-Native

Guidance for AI coding agents (and humans). Keep it current when the interface
or the surrounding facts change.

## What this project is

A native macOS **menu bar app + CLI** for managing LXC-style system containers
on Apple Silicon, built on Apple's `container` CLI. This is the Swift rewrite of
the original `appbox` bash script (kept for posterity in the sibling `appbox`
repo, which is no longer where development happens).

A **box** is a container run with `--init` + `sleep infinity` so it stays up in
the background; you attach with `container exec`. The host dir
`$APPBOX_HOME/<name>/data` is bind-mounted at `/data` and survives even
`destroy` (unless `--purge`).

- **Platform:** Apple Silicon, macOS 15+, Swift 6 / Xcode 26. Everything is arm64.

## Repo layout

| Path | Purpose |
|---|---|
| `Sources/AppBoxKit/` | The engine. All policy lives here. |
| `Sources/appbox/` | The CLI (swift-argument-parser). |
| `Sources/AppBoxApp/` | The SwiftUI menu bar app. |
| `Tests/AppBoxKitTests/` | 34 tests over the pure logic. |
| `build-app.sh` | Builds and assembles `build/AppBox.app`. No `.xcodeproj`. |

**There is deliberately no Xcode project.** SPM builds the executables and
`build-app.sh` assembles the bundle, so everything builds from the terminal.

## Architecture rules

1. **All policy lives in `AppBoxKit`.** The CLI and the app are both thin. If
   you find yourself writing what-a-box-means logic in a view or a command, it
   belongs in the kit — the whole point is that the two faces cannot drift.
2. **Never locate binaries through a login shell.** A GUI app's `Process` does
   not inherit the user's interactive `PATH`. `ProcessRunner.locate` checks an
   explicit override, then `PATH`, then known install dirs. `/bin/sh -lc` here
   would work in the CLI and silently fail in the app.
3. **The GUI never blocks.** `BoxManager` is synchronous; `BoxStore` runs every
   operation in a detached task and catches *all* errors into `lastError`. A
   failing box must never take the app down.
4. **Polling, not events.** Apple's `container` has no event stream, so
   `BoxStore` polls — 2s while the menu is open, 30s when closed.

### Key types

`Distro` (token → verified arm64 image, package manager, rolling/latest rules) ·
`NameVersion` (order-independent name/version parsing) · `PackageSets` (the
standard toolset per package manager) · `Configuration` (env vars + saved
default distro) · `ProcessRunner` · `ContainerClient` (typed wrapper over the
`container` CLI) · `ContainerModels` (Codable mirrors of its JSON) ·
`BoxManager` (create/provision/destroy/classify).

### Box identity — labels, and the legacy fallback

New boxes are labelled `appbox.managed=1`, `appbox.distro=<distro>`,
`appbox.schema=1`. Boxes created by the old bash script have **no labels**, so
`BoxManager.classify` falls back to shape: init process on `sleep infinity` plus
a `/data` mount. Do not remove that fallback — it is what keeps pre-existing
boxes visible.

### Compatibility contract with the bash script

Same env vars (`APPBOX_HOME`, `APPBOX_IMAGE`, `APPBOX_CONFIG_DIR`,
`APPBOX_CPUS`, `APPBOX_MEMORY`, `APPBOX_DEFAULT_DISTRO`), same
`~/.config/appbox/default-distro` file, same `~/containers/<name>/data` layout.
State lives in `container` plus the data dirs, so old script and new binary see
the same boxes. Keep it that way.

`APPBOX_CONTAINER_BIN` is new — an explicit path to Apple's `container`.

## Registry / platform facts (verified against live registries)

- The official **`archlinux` image is amd64-only** and won't run on Apple
  Silicon. We use Arch Linux ARM (`menci/archlinuxarm:base`, rolling). It's
  ALARM rather than Arch proper, but it's the realistic arm64 Arch and uses
  pacman.
- **Rocky publishes no `latest` tag** — only numeric majors on
  `quay.io/rockylinux/rockylinux`. `latest` resolves to `10`.
- `ubuntu:latest` tracks the newest **LTS** (Docker convention — never interim
  releases).
- **pacman 7 needs `--disable-sandbox`.** Its downloader sandbox uses Landlock,
  which the container kernel lacks; without it you get "restricting filesystem
  access failed because Landlock is not supported by the kernel".
- **dnf aborts the whole transaction on one unavailable package**, and `htop` is
  in EPEL rather than Rocky's default repos — a plain `dnf install` of the
  toolset installed *nothing* on Rocky. `PackageSets` now probes for
  `--skip-unavailable` (dnf5, Fedora 41+) and falls back to
  `--setopt=strict=0 --skip-broken` (dnf4, which Rocky 10 still ships).

## Constraints inherited from Apple `container`

- **No systemd as PID 1** — systemd-dependent services (auto-starting sshd,
  cron) aren't supported. Attach and launch daemons manually.
- **IPs are DHCP** and change across restarts. Never hardcode one.
- **CLI/daemon version skew breaks networking** (`no available interface
  strategy for network default … variant=nil`). The app detects it and offers a
  service restart.

## How to work in this repo

- **Verify before committing:**
  - `swift build && swift test`
  - `./build-app.sh --debug --run` to exercise the app itself.
  - End-to-end: create real boxes into a throwaway `APPBOX_HOME` /
    `APPBOX_CONFIG_DIR` (`mktemp -d`), then `destroy <name> --purge`. Arch is
    the best smoke test — it validates the arm64 image *and* pacman.
  - Rocky is the best **provisioning** smoke test — it's where the dnf
    unavailable-package bug surfaced.
- **Never `pkill AppBox` while the user may be using it.** A long provision runs
  as a child of the app; killing the app kills the install mid-transaction.
- Update `README.md` whenever the interface changes.
