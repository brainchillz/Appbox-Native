import Testing

@testable import AppBoxKit

/// These lock in registry facts that were verified against live registries and
/// are easy to regress: Rocky has no `latest` tag, the official Arch image is
/// amd64-only, and `ubuntu:latest` means newest LTS.
@Suite("Image resolution")
struct DistroTests {

    @Test("bare distro tokens resolve to latest")
    func bareTokens() {
        #expect(Distro.resolveImage(token: "ubuntu") == "ubuntu:latest")
        #expect(Distro.resolveImage(token: "debian") == "debian:latest")
        #expect(Distro.resolveImage(token: "alpine") == "alpine:latest")
        #expect(Distro.resolveImage(token: "fedora") == "fedora:latest")
    }

    @Test("inline version suffixes are split off")
    func inlineVersions() {
        #expect(Distro.resolveImage(token: "ubuntu24.04") == "ubuntu:24.04")
        #expect(Distro.resolveImage(token: "ubuntu26.04") == "ubuntu:26.04")
        #expect(Distro.resolveImage(token: "fedora43") == "fedora:43")
        #expect(Distro.resolveImage(token: "fedora44") == "fedora:44")
    }

    /// Rocky publishes no `latest` tag on quay.io/rockylinux/rockylinux, so
    /// both the bare shortcut and an explicit `latest` must land on a real
    /// numeric major or the pull 404s.
    @Test("rocky never resolves to a latest tag")
    func rockyHasNoLatest() {
        #expect(Distro.resolveImage(token: "rocky") == "quay.io/rockylinux/rockylinux:10")
        #expect(Distro.resolveImage(token: "rocky10") == "quay.io/rockylinux/rockylinux:10")
        #expect(Distro.resolveImage(token: "rocky9") == "quay.io/rockylinux/rockylinux:9")
        #expect(Distro.rocky.image(version: "latest") == "quay.io/rockylinux/rockylinux:10")
        #expect(!Distro.rocky.publishesLatestTag)
    }

    /// The official `archlinux` image is amd64-only and will not run on Apple
    /// Silicon; we must stay on Arch Linux ARM.
    @Test("arch uses the arm64 ALARM image and ignores versions")
    func archIsRolling() {
        #expect(Distro.resolveImage(token: "arch") == "menci/archlinuxarm:base")
        #expect(Distro.arch.image(version: "2024.01") == "menci/archlinuxarm:base")
        #expect(Distro.arch.isRolling)
    }

    @Test("unknown tokens pass through as raw image references")
    func rawPassthrough() {
        #expect(Distro.resolveImage(token: "busybox:latest") == "busybox:latest")
        #expect(
            Distro.resolveImage(token: "ghcr.io/acme/thing:v1") == "ghcr.io/acme/thing:v1")
        #expect(Distro.parse(token: "busybox") == nil)
    }

    @Test("non-numeric suffixes are not mistaken for versions")
    func suffixIsNotAVersion() {
        // "ubuntu-server" must not become ubuntu:-server.
        #expect(Distro.resolveImage(token: "ubuntu-server") == "ubuntu-server")
    }

    @Test("package managers map correctly")
    func packageManagers() {
        #expect(Distro.ubuntu.packageManager == .apt)
        #expect(Distro.debian.packageManager == .apt)
        #expect(Distro.fedora.packageManager == .dnf)
        #expect(Distro.rocky.packageManager == .dnf)
        #expect(Distro.alpine.packageManager == .apk)
        #expect(Distro.arch.packageManager == .pacman)
    }

    /// pacman 7's downloader sandbox uses Landlock, which Apple's container
    /// kernel does not support — without --disable-sandbox provisioning fails.
    @Test("pacman provisioning disables the Landlock sandbox")
    func pacmanNeedsDisableSandbox() {
        #expect(PackageSets.installCommand(for: .pacman).contains("--disable-sandbox"))
    }

    @Test("apt provisioning is non-interactive")
    func aptIsNonInteractive() {
        let command = PackageSets.installCommand(for: .apt)
        #expect(command.contains("DEBIAN_FRONTEND=noninteractive"))
        #expect(command.contains("--no-install-recommends"))
    }
}

@Suite("Distro inference from image references")
struct DistroInferenceTests {

    @Test("recognises fully-qualified registry references")
    func qualifiedReferences() {
        #expect(Distro.infer(fromImage: "docker.io/library/ubuntu:latest")?.distro == .ubuntu)
        #expect(Distro.infer(fromImage: "docker.io/library/alpine:latest")?.distro == .alpine)
        #expect(Distro.infer(fromImage: "ubuntu:24.04")?.distro == .ubuntu)
    }

    /// The repository name differs from the appbox token for these two.
    @Test("maps rockylinux and Arch Linux ARM to their appbox tokens")
    func aliases() {
        let rocky = Distro.infer(fromImage: "quay.io/rockylinux/rockylinux:10")
        #expect(rocky?.distro == .rocky)
        #expect(rocky?.version == "10")

        #expect(Distro.infer(fromImage: "menci/archlinuxarm:base")?.distro == .arch)
    }

    @Test("latest and base are not treated as versions")
    func placeholderTagsAreNotVersions() {
        #expect(Distro.infer(fromImage: "ubuntu:latest")?.version == nil)
        #expect(Distro.infer(fromImage: "menci/archlinuxarm:base")?.version == nil)
        #expect(Distro.infer(fromImage: "fedora:43")?.version == "43")
    }

    @Test("unrelated images are not identified")
    func unrelatedImages() {
        #expect(Distro.infer(fromImage: "docker.io/library/nginx:latest") == nil)
        #expect(Distro.infer(fromImage: "ghcr.io/acme/thing:v1") == nil)
    }
}

/// Regression: provisioning a Rocky box installed *nothing*, because htop is
/// not in Rocky's default repos and dnf aborts the whole transaction when any
/// requested package is unavailable.
@Suite("Provisioning resilience")
struct ProvisioningResilienceTests {

    @Test("dnf skips unavailable packages instead of failing the transaction")
    func dnfSkipsUnavailable() {
        let command = PackageSets.installCommand(for: .dnf)
        // dnf5 spelling and the dnf4 fallback must both be present, since the
        // command probes at runtime.
        #expect(command.contains("--skip-unavailable"))
        #expect(command.contains("strict=0"))
        #expect(command.contains("dnf install -y"))
    }

    @Test("every package manager gets a non-interactive command")
    func allManagersAreNonInteractive() {
        for manager in PackageManager.allCases {
            let command = PackageSets.installCommand(for: manager)
            #expect(!command.isEmpty)
            // None may block waiting for a yes/no prompt.
            switch manager {
            case .apt: #expect(command.contains("-y"))
            case .dnf: #expect(command.contains("-y"))
            case .apk: #expect(command.contains("--no-cache"))
            case .pacman: #expect(command.contains("--noconfirm"))
            }
        }
    }
}
