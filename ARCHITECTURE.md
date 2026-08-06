# Architecture

Design notes and hard-won platform facts for anyone working on this codebase.
Keep it current when the interface or the surrounding facts change.

## What this project is

A native macOS **menu bar app + CLI** for managing persistent Linux
environments on Apple Silicon, built on Apple's `container` CLI. It is the Swift
rewrite of an earlier `appbox` bash script.

There are **two kinds of box**, and the whole design turns on the difference.

A **machine** is Apple's own container machine (`container machine`, added in
`container` 1.1.0). It runs the image's init system — systemd where the image
has one — and `container` mounts your Mac home at `/Users/<you>` and creates a
Linux account matching your host uid, gid and name. This is what appbox spent
its first two versions imitating, and it is the default for new boxes.

A **container** is appbox's original box: `container run --init … sleep
infinity`, attached with `container exec`. It gets a *private* per-box home plus
`$APPBOX_HOME/<name>/data` at `/data`, both surviving `destroy` unless
`--purge`. Machines can do neither, so containers remain a deliberate choice
rather than a legacy path.

The two live in **separate namespaces** in Apple's CLI — `container machine ls`
and `container ls` do not see each other, and the same name may exist in both.
That is why `Box` carries a `kind`, why `Box.id` is `kind:name` rather than the
name, and why every operation dispatches on a `Box` rather than a bare string.

## Layout

| Path | Purpose |
|---|---|
| `Sources/AppBoxKit/` | The engine. All policy lives here. |
| `Sources/appbox/` | The CLI (swift-argument-parser). |
| `Sources/AppBoxApp/` | The SwiftUI menu bar app. |
| `Tests/AppBoxKitTests/` | Tests over the pure logic. |
| `Tools/make-icon.swift` | Generates `Resources/AppIcon.icns`. |
| `build-app.sh` | Builds and assembles `build/AppBox.app`. |
| `package.sh` | Produces a distributable DMG. |

Inside the kit, the split is by kind with a facade over both:
`ContainerClient`/`BoxManager` for containers, `MachineClient`/`MachineManager`
for machines, and **`BoxService`** as the single door the CLI and the app use.
Neither face should ever reach past `BoxService` to a specific manager unless
the operation genuinely only exists for one kind (`machine set-default`, a
container's `--purge`).

**There is deliberately no Xcode project.** SPM builds the executables and
`build-app.sh` assembles the bundle, so everything builds from the terminal.

## Rules

1. **All policy lives in `AppBoxKit`.** The CLI and the app are both thin. If
   you find yourself writing what-a-box-means logic in a view or a command, it
   belongs in the kit — the whole point is that the two faces cannot drift.
2. **Never locate binaries through a login shell.** A GUI app's `Process` does
   not inherit the user's interactive `PATH`. `ProcessRunner.locate` checks an
   explicit override, then `PATH`, then known install directories. Using
   `/bin/sh -lc` here would work in the CLI and silently fail in the app.
3. **The GUI never blocks.** `BoxManager` is synchronous; `BoxStore` runs every
   operation in a detached task and catches *all* errors into `lastError`. A
   failing box must never take the app down.
4. **Polling, not events.** Apple's `container` has no event stream, so
   `BoxStore` polls — 2s while the menu is open, 30s when closed.
5. **Compare file paths, not URLs.** `URL(fileURLWithPath:)` stats the
   filesystem and appends a trailing slash for an existing directory, so URLs
   for the same directory built two different ways compare unequal despite
   identical `.path`. `CLIInstaller.normalized` exists for this.

## Key types

Shared: `Distro` (token → verified arm64 image, package manager, rolling/latest
rules) · `NameVersion` (order-independent name/version parsing) · `PackageSets`
(the standard toolset per package manager) · `DefaultDotfiles` · `Configuration`
(env vars + the saved default distro) · `ImageResolver` (token → image, used by
both kinds so they cannot disagree) · `ProcessRunner` · `Box`/`BoxKind` ·
`BoxService` (the facade) · `CLIInstaller`.

Containers: `ContainerClient` · `ContainerModels` · `BoxManager` · `BaseImage`
(cached `appbox-base/` images carrying the toolset **and** the user account).

Machines: `MachineClient` · `MachineModels` · `MachineManager` · `MachineImage`
(cached `appbox-machine/` images carrying an init system and the toolset, but
**not** an account — `container` makes that itself on first boot).

## Machine facts, all verified against `container` 1.1.0

These cost real time to find. Do not undo the workarounds without re-testing.

- **`container machine run` re-tokenises its trailing arguments.** A shell
  string passed as `run -- /bin/sh -c '<script>'` arrives mangled: words are
  dropped or appended to the wrong argument, so `apt-get install -y curl vim`
  silently becomes something else. Scripts therefore travel on **stdin**
  (`MachineClient.runScript` → `run -i -- /bin/sh` with the script piped), which
  needs `--interactive` because stdin is otherwise not forwarded, and which is
  why `ProcessRunner.run` grew a `stdin:` parameter. A plain command with
  separate arguments (`run -- /bin/echo a b c`) is fine.
- **The first `run` on a freshly created machine rejects piped stdin**, failing
  with "Inappropriate ioctl for device" — an error that sounds like a terminal
  problem and is not. Any plain run gets past it, after which piped runs work
  forever. `MachineClient.warmUp` does exactly that, and `runScript` retries
  once when it sees that error.
- **`machine create` returns before the boot finishes.** Running anything in the
  gap hits the error above. `MachineManager.waitUntilRunning` polls first.
- **Most images cannot boot as a machine.** A machine runs the image's own init,
  and `ubuntu:latest` has no `/sbin/init` — the machine is created and then dies
  with "no PID data from sync pipe". On Debian and Ubuntu the package that
  provides `/sbin/init` is **`systemd-sysv`**, not `systemd`. Alpine is the only
  distro appbox offers that boots as shipped (BusyBox init). Every recipe ends
  with `RUN test -x /sbin/init` so a mistake fails the build, not the boot.
- **`systemd-modules-load.service` always fails** — the machine kernel loads no
  modules — leaving `systemctl is-system-running` at "degraded" on an otherwise
  perfect machine. The recipe masks it.
- **`list` and `inspect` return different shapes.** `list --format json` is a
  summary (id, status, cpus, memory, diskSize, ipAddress, **default**) and is
  the only one that reports the default machine; `inspect` has image,
  `homeMount` and `userSetup` but no default flag. `MachineRecord` is the union
  and `MachineClient.list` merges them, one `inspect` per machine.
- **There is no `machine start`.** Booting is a side effect of `run`, so
  `MachineClient.boot` runs `/bin/true` detached purely for that.
- **`machine set` is read at boot**, so `MachineManager.configure` stops a
  running machine, applies the change and starts it again — otherwise the
  setting appears to do nothing until something else restarts it.
- **`$HOME` inside is not your Mac home.** `/home/<you>` is on the machine's own
  (sparse, ~500G) disk and dies with the machine; your Mac home is mounted
  separately at `/Users/<you>`. Apple's documentation says otherwise; it is
  wrong on this point. Anything a user cares about belongs under `/Users/<you>`,
  which is why `destroy` says so out loud.
- **What `container`'s first-boot setup leaves out**: `sudo`, a bash login
  shell, and any dotfiles at all. `MachineManager.polish` adds them after first
  boot rather than baking a second account into the image, which would collide
  with the one `container` creates at the same uid. It is idempotent and every
  step is guarded, because "Install Standard Toolset" re-runs it.

## Box identity — labels, and the legacy fallback

New boxes are labelled `appbox.managed=1`, `appbox.distro=<distro>`,
`appbox.schema=1`. Boxes created by the earlier bash script have **no labels**,
so `BoxManager.classify` falls back to shape: an init process parked on
`sleep infinity` plus a `/data` mount. Do not remove that fallback — it is what
keeps pre-existing boxes visible.

## Compatibility contract

Same environment variables (`APPBOX_HOME`, `APPBOX_IMAGE`, `APPBOX_CONFIG_DIR`,
`APPBOX_CPUS`, `APPBOX_MEMORY`, `APPBOX_DEFAULT_DISTRO`), the same
`~/.config/appbox/default-distro` file, and the same `~/containers/<name>/data`
layout as the original script. State lives in `container` plus the data
directories, so the old script and this binary see the same boxes. Keep it that
way. `APPBOX_CONTAINER_BIN` is new — an explicit path to Apple's `container`.

## Registry facts (verified against live registries)

- The official **`archlinux` image is amd64-only** and will not run on Apple
  Silicon. We use Arch Linux ARM (`menci/archlinuxarm:base`, rolling). It is
  ALARM rather than Arch proper, but it is the realistic arm64 Arch and uses
  pacman.
- **Rocky publishes no `latest` tag** — only numeric majors on
  `quay.io/rockylinux/rockylinux`. `latest` resolves to `10`.
- `ubuntu:latest` tracks the newest **LTS** (Docker convention — never interim
  releases).
- **pacman 7 needs `--disable-sandbox`.** Its downloader sandbox uses Landlock,
  which the container kernel lacks; without the flag it fails with "restricting
  filesystem access failed because Landlock is not supported by the kernel".
- **dnf aborts the whole transaction on one unavailable package**, and `htop`
  ships in EPEL rather than Rocky's default repositories — so a plain
  `dnf install` of the toolset installed *nothing* on Rocky. `PackageSets`
  probes for `--skip-unavailable` (dnf5, Fedora 41+) and falls back to
  `--setopt=strict=0 --skip-broken` (dnf4, which Rocky 10 still ships).

## Constraints inherited from Apple `container`

- **Containers have no systemd as PID 1** — systemd-dependent services
  (auto-starting sshd, cron) are not supported in a container. Attach and launch
  daemons manually. **Machines lift this**: they run the image's init, so
  `systemctl enable --now nginx` works and survives a restart. Verified.
- **Machines take no extra mounts.** `machine create` has no `--volume`, so
  `/data` and a private per-box home exist only for containers. This is the one
  real reason to still create one.
- **Every machine shares your one Mac home.** There is no isolation between
  machines, and `rm -rf ~` inside reaches your real files. `--home-mount ro` or
  `none` is the only mitigation, and it is offered at create time for that
  reason.
- **IPs are DHCP** and change across restarts. Never hardcode one.
- **CLI/daemon version skew breaks networking** (`no available interface
  strategy for network default … variant=nil`). The app detects it and offers a
  service restart.

## Working on this

- **Verify before committing:**
  - `swift build && swift test`
  - `./build-app.sh --debug --run` to exercise the app itself. Note that `open`
    on a bundle that is already running just re-activates the old process —
    quit it first or you will test the previous build.
  - End to end: create real boxes into a throwaway `APPBOX_HOME` /
    `APPBOX_CONFIG_DIR` (`mktemp -d`), then destroy them. Arch is the best smoke
    test — it validates the arm64 image *and* pacman.
  - Rocky is the best **provisioning** smoke test; it is where the dnf
    unavailable-package bug surfaced.
  - For machines, Ubuntu is the one that matters: it is the recipe that has to
    add an init system, and the check is
    `systemctl is-system-running` reporting `running` with no failed units.
    Changing `MachineImage` means deleting the cached `appbox-machine/<distro>`
    image (or bumping `recipeVersion`), or the old one is silently reused.
- **Do not kill the app while an operation is in flight.** A long provision runs
  as a child of the app; terminating the app kills the install mid-transaction.
- Update `README.md` whenever the interface changes.
