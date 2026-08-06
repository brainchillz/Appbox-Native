import Foundation
import Testing

@testable import AppBoxKit

/// Real output from `container machine inspect` (container CLI 1.1.0), so a
/// schema change in Apple's CLI shows up as a failing test rather than a
/// runtime surprise.
private let inspectJSON = """
    [
      {
        "containerId" : "dev-f6e436",
        "cpus" : 6,
        "createdDate" : "2026-08-05T23:52:33Z",
        "diskSize" : 78745600,
        "homeMount" : "rw",
        "id" : "dev",
        "image" : {
          "descriptor" : {
            "digest" : "sha256:28bd5fe8b56d",
            "mediaType" : "application/vnd.oci.image.index.v1+json",
            "size" : 9218
          },
          "reference" : "docker.io/library/alpine:latest"
        },
        "ipAddress" : "192.168.64.11",
        "memory" : 51539607552,
        "platform" : { "architecture" : "arm64", "os" : "linux" },
        "startedDate" : "2026-08-05T23:52:35Z",
        "status" : "running",
        "userSetup" : { "gid" : 20, "uid" : 501, "username" : "daver" }
      }
    ]
    """

/// `machine list --format json` is a different, smaller shape than `inspect` —
/// no image, no user, no home-mount, but it alone reports the default.
private let listJSON = """
    [{"memory":51539607552,"ipAddress":"192.168.64.17","default":true,
      "createdDate":"2026-08-06T00:24:33Z","cpus":6,"diskSize":78729216,
      "status":"running","id":"dev"}]
    """

private let stoppedListJSON = """
    [{"status":"stopped","cpus":6,"createdDate":"2026-08-06T00:24:33Z","id":"dev",
      "diskSize":78790656,"default":false,"memory":51539607552}]
    """

private func decode(_ json: String) throws -> MachineRecord {
    try JSONDecoder().decode([MachineRecord].self, from: Data(json.utf8))[0]
}

@Suite("Machine JSON decoding")
struct MachineModelTests {

    @Test("decodes the full inspect record")
    func decodesInspect() throws {
        let record = try decode(inspectJSON)
        #expect(record.id == "dev")
        #expect(record.status == .running)
        #expect(record.ipAddress == "192.168.64.11")
        #expect(record.image?.reference == "docker.io/library/alpine:latest")
        #expect(record.homeMount == .rw)
        #expect(record.userSetup?.username == "daver")
        #expect(record.userSetup?.uid == 501)
        #expect(record.userSetup?.homeDirectory == "/home/daver")
        #expect(record.memoryDescription == "48G")
    }

    @Test("decodes the summary shape, which omits most of the record")
    func decodesList() throws {
        let record = try decode(listJSON)
        #expect(record.id == "dev")
        #expect(record.isDefault)
        #expect(record.image == nil)
        #expect(record.userSetup == nil)
        // Absent rather than false: only `list` knows, so a merged record must
        // not claim a machine is non-default just because `inspect` was quiet.
        #expect(try decode(inspectJSON).default == nil)
    }

    @Test("a stopped machine reports no IP and stays listed")
    func stopped() throws {
        let record = try decode(stoppedListJSON)
        #expect(record.status == .stopped)
        #expect(record.ipAddress == nil)
        #expect(!record.isDefault)
    }

    @Test("merging keeps the summary's default flag and takes inspect's detail")
    func merge() throws {
        let merged = try decode(listJSON).merging(detail: decode(inspectJSON))
        #expect(merged.isDefault)
        #expect(merged.image?.reference == "docker.io/library/alpine:latest")
        #expect(merged.homeMount == .rw)
        #expect(merged.userSetup?.username == "daver")
        // The summary's own IP wins — it is the fresher of the two calls.
        #expect(merged.ipAddress == "192.168.64.17")
    }

    @Test("an unrecognised state decodes as unknown rather than throwing")
    func unknownState() throws {
        let record = try decode(
            #"[{"id":"dev","status":"booting","cpus":2,"memory":2147483648}]"#)
        #expect(record.status == .unknown)
    }
}

@Suite("Machine image recipes")
struct MachineImageTests {

    @Test("tags are namespaced apart from container base images")
    func reference() {
        #expect(MachineImage(distro: .ubuntu).reference == "appbox-machine/ubuntu:latest-v1")
        #expect(
            MachineImage(distro: .fedora, version: "43").reference
                == "appbox-machine/fedora:43-v1")
        // Must not collide with the images that back plain containers.
        #expect(
            MachineImage(distro: .ubuntu).reference
                != BaseImage(
                    distro: .ubuntu, version: nil,
                    user: HostUser(name: "daver", uid: 501, gid: 20)
                ).reference)
    }

    @Test("built from the same upstream image the distro resolves to")
    func sourceImage() {
        #expect(MachineImage(distro: .rocky).sourceImage == "quay.io/rockylinux/rockylinux:10")
        #expect(MachineImage(distro: .arch).sourceImage == "menci/archlinuxarm:base")
    }

    /// Regression: `container machine create ubuntu:latest` creates the machine
    /// and then dies with "no PID data from sync pipe", because the stock image
    /// has no /sbin/init. systemd alone does not install one on Debian and
    /// Ubuntu — systemd-sysv is what provides it.
    @Test("Debian-family recipes install systemd-sysv, which is what provides /sbin/init")
    func debianInit() {
        for distro in [Distro.ubuntu, .debian] {
            let dockerfile = MachineImage(distro: distro).dockerfile
            #expect(dockerfile.contains("systemd-sysv"))
            #expect(dockerfile.contains("systemctl set-default multi-user.target"))
        }
    }

    @Test("Alpine needs no init package — BusyBox already provides one")
    func alpineInit() {
        let image = MachineImage(distro: .alpine)
        #expect(image.initPackages.isEmpty)
        #expect(image.initInstallCommand == nil)
        #expect(!image.dockerfile.contains("systemctl"))
    }

    @Test("every recipe asserts /sbin/init at build time rather than at boot")
    func initAssertion() {
        for distro in Distro.allCases {
            #expect(MachineImage(distro: distro).dockerfile.contains("RUN test -x /sbin/init"))
        }
    }

    @Test("the toolset goes in too — machine images ship no sudo, curl or bash")
    func toolset() {
        #expect(MachineImage(distro: .ubuntu).dockerfile.contains("apt-get install"))
        #expect(MachineImage(distro: .alpine).dockerfile.contains("apk add --no-cache"))
        // pacman 7's Landlock sandbox is unsupported by the container kernel.
        #expect(MachineImage(distro: .arch).dockerfile.contains("--disable-sandbox"))
        #expect(MachineImage(distro: .ubuntu).dockerfile.contains("sudo"))
    }

    @Test("recipes are labelled so a stale cache can be told apart")
    func labels() {
        let dockerfile = MachineImage(distro: .ubuntu).dockerfile
        #expect(dockerfile.contains("appbox.machine=\"1\""))
        #expect(dockerfile.contains("appbox.recipe=\"1\""))
    }
}

@Suite("Machine command construction")
struct MachineClientTests {

    private func spec(_ build: (inout MachineClient.CreateSpec) -> Void = { _ in })
        -> MachineClient.CreateSpec
    {
        var spec = MachineClient.CreateSpec(name: "dev", image: "alpine:latest")
        build(&spec)
        return spec
    }

    @Test("a plain create names the machine and puts the image last")
    func minimal() {
        #expect(spec().arguments == ["create", "--name", "dev", "alpine:latest"])
    }

    @Test("options are passed in the CLI's own spelling")
    func options() {
        let arguments = spec {
            $0.cpus = 4
            $0.memory = "8G"
            $0.homeMount = .ro
            $0.setDefault = true
        }.arguments

        #expect(arguments.contains(["--cpus", "4"]))
        #expect(arguments.contains(["--memory", "8G"]))
        #expect(arguments.contains(["--home-mount", "ro"]))
        #expect(arguments.contains("--set-default"))
        #expect(arguments.last == "alpine:latest")
    }

    @Test("nested virtualization travels with a kernel that supports it")
    func virtualization() {
        let arguments = spec {
            $0.virtualization = true
            $0.kernel = "/tmp/vmlinux-kvm"
        }.arguments
        #expect(arguments.contains("--virtualization"))
        #expect(arguments.contains(["--kernel", "/tmp/vmlinux-kvm"]))
    }

    @Test("an empty kernel path is omitted rather than passed as an empty flag")
    func emptyKernel() {
        #expect(!spec { $0.kernel = "" }.arguments.contains("--kernel"))
    }
}

@Suite("Machine account setup")
struct MachinePolishTests {

    private let account = MachineUser(username: "daver", uid: 501, gid: 20)

    private var script: String {
        MachineManager(
            client: MachineClient(
                container: ContainerClient(binary: URL(fileURLWithPath: "/usr/local/bin/container"))),
            config: Configuration(
                home: URL(fileURLWithPath: "/tmp"), configDir: URL(fileURLWithPath: "/tmp"))
        ).polishScript(for: account)
    }

    @Test("gives the account sudo and a bash login shell")
    func sudoAndShell() {
        #expect(script.contains("NOPASSWD:ALL"))
        #expect(script.contains("/etc/sudoers.d/daver"))
        #expect(script.contains("usermod -s /bin/bash daver"))
    }

    /// Minimal images have no `usermod` — it comes from shadow, which Alpine
    /// does not install by default — so the shell change needs a fallback that
    /// only uses what BusyBox provides.
    @Test("falls back to awk where usermod is missing")
    func usermodFallback() {
        #expect(script.contains("command -v usermod"))
        #expect(script.contains("awk -F: -v u=daver"))
    }

    @Test("seeds an empty home, preferring the distro's own skeleton")
    func dotfiles() {
        #expect(script.contains("cp -a /etc/skel/."))
        #expect(script.contains("/home/daver/.bashrc"))
        #expect(script.contains("HISTCONTROL=ignoreboth"))
        #expect(script.contains("chown -R 501:20 /home/daver"))
    }

    /// Every write is guarded, because this runs again on every "Install
    /// Standard Toolset" — it must not overwrite dotfiles you have edited.
    @Test("does not clobber an existing home")
    func idempotent() {
        #expect(script.contains("if [ ! -e /home/daver/.bashrc ]"))
        #expect(script.contains("if [ ! -e /home/daver/.profile ]"))
    }

    /// The dotfiles arrive as quoted heredocs, so `$PS1` and friends reach the
    /// file unexpanded. An unquoted delimiter would strip them to nothing.
    @Test("heredoc delimiters are quoted and terminated at column zero")
    func heredocs() {
        #expect(script.contains("<<'APPBOX_BASHRC_EOF'"))
        #expect(script.contains("\nAPPBOX_BASHRC_EOF\n"))
        #expect(script.contains("<<'APPBOX_PROFILE_EOF'"))
        #expect(script.contains("\nAPPBOX_PROFILE_EOF\n"))
    }
}

@Suite("Box identity across kinds")
struct BoxKindTests {

    private func box(_ kind: BoxKind, _ name: String) -> Box {
        Box(kind: kind, name: name, state: .running, image: "x", managed: .labelled,
            cpus: 1, memory: "1G")
    }

    /// The two kinds are separate namespaces in Apple's CLI, so the same name
    /// can legitimately exist twice. Identity has to carry the kind or the
    /// menu bar list collapses them into one row.
    @Test("a machine and a container may share a name but not an identity")
    func identity() {
        #expect(box(.machine, "dev").id != box(.container, "dev").id)
        #expect(box(.machine, "dev").id == box(.machine, "dev").id)
    }

    @Test("only a container has host data to keep")
    func hostData() {
        var machine = box(.machine, "dev")
        machine.dataDirectory = nil
        #expect(!machine.hasHostData)
    }
}
