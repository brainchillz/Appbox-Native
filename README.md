# AppBox Native

A native macOS app and CLI for running **LXC-style system containers** on Apple
Silicon, built on Apple's [`container`](https://github.com/apple/container) tool.

A *box* is a named, persistent Linux machine: you shell into it, install
packages in it, and its state survives stop/start. A host directory is
bind-mounted at `/data` so the data you can't lose outlives the container
itself.

This is the Swift rewrite of the original [`appbox`](../appbox) shell script.
The script still exists and still works — this repo is where the project
continues.

---

## What you get

**A menu bar app.** A persistent icon by the clock with a dropdown listing every
box, its running/stopped state, and a switch to flip it on or off. Create,
inspect, provision and destroy boxes from a management window; open a real
shell in Terminal with one click.

**A CLI.** The same functionality from the command line, sharing the exact same
engine — `AppBoxKit`. The GUI and the CLI cannot drift apart because there is
only one implementation of what a box *is*.

## Requirements

- Apple Silicon Mac, macOS 15+
- Apple's `container` CLI — install the signed `.pkg` from
  [github.com/apple/container/releases](https://github.com/apple/container/releases)
  (there is no Homebrew cask)
- Xcode 26 / Swift 6 to build

## Build

```sh
./build-app.sh --release          # -> build/AppBox.app
./build-app.sh --debug --run      # fast build, then launch
cp -R build/AppBox.app /Applications/
```

There is no `.xcodeproj`. SPM builds the executables and `build-app.sh`
assembles the bundle, so the whole project builds from the command line.

The app is **ad-hoc signed** — enough to run on the machine that built it.
Distributing it to another Mac requires a Developer ID identity and
notarization. It cannot be sandboxed (it spawns processes and reads
`~/containers`), so there is no Mac App Store path.

The `appbox` CLI is bundled inside the app at `Contents/Helpers/appbox`, so one
download provides both interfaces.

```sh
swift build          # just the binaries
swift test           # 32 tests
```

## CLI usage

```
appbox create        <name> [image|distro] [--full]   # uses your default distro if none given
appbox create-ubuntu <name> [24.04|26.04|latest]      # latest = newest LTS
appbox create-debian <name> [version|latest]
appbox create-alpine <name> [version|latest]
appbox create-fedora <name> [43|44|latest]
appbox create-rocky  <name> [9|10|latest]             # latest = 10
appbox create-arch   <name>                           # rolling — always latest

appbox set-default   [distro|--clear]   # distro used by a bare `create`
appbox provision     <name>             # install the standard CLI toolset
appbox shell|exec|start|stop|restart|list|ip|info|destroy
```

`--full` on any create command also installs the standard toolset. Version and
name may be given in **either order** — `create-ubuntu web 24.04` and
`create-ubuntu 24.04 web` are the same thing.

### Configuration

All environment-overridable, and identical to the original script so both can
coexist:

| Variable | Default | Meaning |
|---|---|---|
| `APPBOX_HOME` | `~/containers` | per-box host data |
| `APPBOX_IMAGE` | *(unset)* | forces the image for a bare `create` |
| `APPBOX_CONFIG_DIR` | `~/.config/appbox` | appbox's own config |
| `APPBOX_CPUS` | `4` | default CPUs |
| `APPBOX_MEMORY` | `2G` | default memory |
| `APPBOX_DEFAULT_DISTRO` | *(unset)* | overrides the saved default |
| `APPBOX_CONTAINER_BIN` | *(auto)* | explicit path to `container` |

## Architecture

```
Sources/AppBoxKit/     the engine — all policy lives here
  Distro              distro → verified arm64 image, package manager
  NameVersion         order-independent <name>/[version] parsing
  PackageSets         the standard toolset, per package manager
  Configuration       env vars + the saved default distro
  ProcessRunner       locates and runs binaries (never via a login shell)
  ContainerClient     typed wrapper over Apple's `container` CLI
  ContainerModels     Codable mirrors of `container … --format json`
  BoxManager          what a "box" is: create, provision, destroy, classify

Sources/appbox/        the CLI (swift-argument-parser)
Sources/AppBoxApp/     the SwiftUI menu bar app
```

Two decisions worth knowing:

**Binaries are located explicitly, never through a login shell.** A GUI app's
`Process` does not inherit your interactive `PATH`, so the app and the CLI must
find `container` the same deliberate way or they will disagree about whether
it's even installed.

**Boxes are labelled.** New boxes get `appbox.managed=1` plus `appbox.distro`,
so the app can tell our containers from anything else on the machine without
guessing. Boxes made by the original shell script have no labels, so they're
matched by *shape* instead — an init process parked on `sleep infinity` plus a
`/data` mount. Your existing boxes keep working untouched.

## Inherited constraints

These come from Apple's `container` and are not bugs in appbox:

- **No systemd as PID 1.** Boxes run `--init` and `sleep infinity`, so
  systemd-dependent services (auto-starting sshd, cron) aren't supported.
  Attach with `appbox shell` and launch daemons manually.
- **IPs are DHCP** and can change across restarts. Use the box name or
  `appbox ip <name>`, never a hardcoded address.
- **CLI/daemon version skew breaks networking**, with errors like
  `no available interface strategy for network default … variant=nil`. The app
  detects this and offers to restart the service; by hand it's
  `container system stop && container system start`.

## Registry facts

Verified against live registries — these are easy to get wrong:

| Distro | Image | Notes |
|---|---|---|
| Ubuntu | `ubuntu:latest` | `latest` tracks the newest **LTS**, never interim releases |
| Debian | `debian:latest` | |
| Alpine | `alpine:latest` | |
| Fedora | `fedora:latest` | |
| Rocky | `quay.io/rockylinux/rockylinux:{10,9}` | **no `latest` tag exists**; `latest` resolves to 10 |
| Arch | `menci/archlinuxarm:base` | the official `archlinux` image is **amd64-only**; this is Arch Linux ARM, rolling |

Also: **pacman 7 needs `--disable-sandbox`** inside a box. Its downloader
sandbox uses Landlock, which the container kernel doesn't support — without the
flag it fails with *"restricting filesystem access failed because Landlock is
not supported by the kernel"*. Provisioning already passes it; add it to any
manual `pacman` run.

## Status

Working: menu bar list with live state and toggles, create, provision, destroy,
shell-in-Terminal, logs, service-health banners, and the full CLI.

Not done yet: app icon, an "Install Command Line Tool" flow, launch-at-login,
and Developer ID signing + notarization.
