import Testing

@testable import AppBoxKit

private let user = HostUser(name: "daver", uid: 501, gid: 20)

@Suite("Base image recipes")
struct BaseImageTests {

    @Test("tags are namespaced and versioned")
    func imageReference() {
        #expect(
            BaseImage(distro: .ubuntu, version: nil, user: user).reference
                == "appbox-base/ubuntu:latest-v1")
        #expect(
            BaseImage(distro: .fedora, version: "43", user: user).reference
                == "appbox-base/fedora:43-v1")
    }

    @Test("built from the same upstream image the distro resolves to")
    func sourceImage() {
        #expect(
            BaseImage(distro: .rocky, version: nil, user: user).sourceImage
                == "quay.io/rockylinux/rockylinux:10")
        #expect(
            BaseImage(distro: .arch, version: nil, user: user).sourceImage
                == "menci/archlinuxarm:base")
    }

    @Test("the recipe installs the toolset and creates the user")
    func dockerfileContents() {
        let dockerfile = BaseImage(distro: .ubuntu, version: nil, user: user).dockerfile
        #expect(dockerfile.hasPrefix("FROM ubuntu:latest"))
        #expect(dockerfile.contains("apt-get install"))
        #expect(dockerfile.contains("useradd -u 501 -g 20"))
        #expect(dockerfile.contains("NOPASSWD:ALL"))
        #expect(dockerfile.contains("appbox.base=\"1\""))
    }

    /// Regression: `addgroup -g 20 staff || true` swallowed a failure on
    /// Alpine (gid 20 already exists there), and the following
    /// `adduser -G staff` then failed with "unknown group staff". BusyBox has
    /// no groupmod, so we use whichever group already owns the gid.
    @Test("alpine uses BusyBox adduser and the existing group for the gid")
    func alpineUserCreation() {
        let commands = BaseImage.userCreationCommands(for: .apk, user: user)
        let script = commands.joined(separator: " && ")

        #expect(script.contains("adduser -D -u 501"))
        #expect(!script.contains("useradd"))
        // Resolves the group name rather than assuming one exists or renaming.
        #expect(script.contains("getent group 20 | cut -d: -f1"))
        #expect(!script.contains("groupmod"))
        // The group is only created when the gid is genuinely free.
        #expect(script.contains("if ! getent group 20"))
    }

    @Test("non-alpine distros use useradd with the numeric gid")
    func standardUserCreation() {
        for manager in [PackageManager.apt, .dnf, .pacman] {
            let script = BaseImage.userCreationCommands(for: manager, user: user)
                .joined(separator: " && ")
            #expect(script.contains("useradd -u 501 -g 20 -m -s /bin/bash daver"))
            #expect(!script.contains("adduser -D"))
        }
    }

    @Test("package caches are cleaned so images stay small")
    func cacheCleanup() {
        #expect(
            BaseImage(distro: .ubuntu, version: nil, user: user).dockerfile
                .contains("rm -rf /var/lib/apt/lists/*"))
        // apk already installs with --no-cache.
        #expect(BaseImage(distro: .alpine, version: nil, user: user).cacheCleanupCommand == nil)
    }
}

@Suite("Host user")
struct HostUserTests {

    @Test("uses the macOS short name, sanitised for Linux")
    func sanitisesName() {
        #expect(HostUser.current(environment: ["APPBOX_USER": "David Rodgers"]).name == "davidrodgers")
        #expect(HostUser.current(environment: ["APPBOX_USER": "daver"]).name == "daver")
        #expect(HostUser.current(environment: ["APPBOX_USER": "dave_r-2"]).name == "dave_r-2")
    }

    @Test("falls back rather than producing an empty username")
    func emptyNameFallback() {
        #expect(HostUser.current(environment: ["APPBOX_USER": "!!!"]).name == "user")
    }

    @Test("home directory follows the username")
    func homeDirectory() {
        #expect(HostUser(name: "daver", uid: 501, gid: 20).homeDirectory == "/home/daver")
    }
}
