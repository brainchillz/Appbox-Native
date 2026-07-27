import Foundation
import Testing

@testable import AppBoxKit

/// Real output captured from `container inspect` (container CLI 1.1.0), trimmed
/// to the fields appbox decodes. Keeping a real sample here means a schema
/// change in Apple's CLI shows up as a failing test rather than a runtime crash.
private func sampleJSON(
    id: String,
    labels: String = "{}",
    mounts: String = """
        [{"destination":"/data","options":[],"source":"/Users/x/containers/dev/data"}]
        """,
    executable: String = "sleep",
    arguments: String = #"["infinity"]"#,
    state: String = "running",
    networks: String = """
        [{"hostname":"dev","ipv4Address":"192.168.64.2/24","ipv4Gateway":"192.168.64.1",
          "macAddress":"f6:b5:dd:91:a2:08","network":"default"}]
        """
) -> Data {
    """
    [{
      "id": "\(id)",
      "status": {"state":"\(state)","networks":\(networks)},
      "configuration": {
        "id": "\(id)",
        "creationDate": "2026-07-11T17:39:58Z",
        "image": {"reference":"ubuntu:latest"},
        "initProcess": {"executable":"\(executable)","arguments":\(arguments)},
        "labels": \(labels),
        "mounts": \(mounts),
        "platform": {"architecture":"arm64","os":"linux"},
        "resources": {"cpus":4,"memoryInBytes":2147483648,"cpuOverhead":1},
        "useInit": true
      }
    }]
    """.data(using: .utf8)!
}

private func decode(_ data: Data) throws -> ContainerRecord {
    try JSONDecoder().decode([ContainerRecord].self, from: data)[0]
}

@Suite("Container JSON decoding")
struct ContainerModelTests {

    @Test("decodes a running box and strips the CIDR suffix from the IP")
    func decodesRunningBox() throws {
        let record = try decode(sampleJSON(id: "dev"))
        #expect(record.id == "dev")
        #expect(record.state == .running)
        #expect(record.ipv4 == "192.168.64.2")
        #expect(record.image == "ubuntu:latest")
        #expect(record.configuration.resources.cpus == 4)
        #expect(record.configuration.resources.memoryDescription == "2G")
    }

    @Test("a stopped box reports no IP")
    func stoppedBoxHasNoIP() throws {
        let record = try decode(sampleJSON(id: "dev", state: "stopped", networks: "[]"))
        #expect(record.state == .stopped)
        #expect(record.ipv4 == nil)
    }

    @Test("an unrecognised state decodes as unknown rather than throwing")
    func unknownState() throws {
        let record = try decode(sampleJSON(id: "dev", state: "restarting", networks: "[]"))
        #expect(record.state == .unknown)
    }
}

@Suite("Managed-box classification")
struct ClassificationTests {

    @Test("a labelled box is definitively ours")
    func labelled() throws {
        let record = try decode(
            sampleJSON(id: "dev", labels: #"{"appbox.managed":"1","appbox.distro":"ubuntu"}"#))
        #expect(BoxManager.classify(record) == .labelled)
    }

    /// Boxes created by the bash script carry no labels, so they must still be
    /// recognised by shape or they would vanish from the app's list.
    @Test("a pre-label box is recognised by its shape")
    func inferredFromShape() throws {
        let record = try decode(sampleJSON(id: "dev", labels: "{}"))
        #expect(BoxManager.classify(record) == .inferred)
    }

    @Test("an unrelated container is not claimed")
    func foreignContainer() throws {
        let nginx = try decode(
            sampleJSON(
                id: "my-web-server",
                mounts: "[]",
                executable: "/docker-entrypoint.sh",
                arguments: #"["nginx","-g","daemon off;"]"#))
        #expect(BoxManager.classify(nginx) == .foreign)
    }

    @Test("sleep infinity without a /data mount is not ours")
    func sleepWithoutDataMount() throws {
        let record = try decode(sampleJSON(id: "other", mounts: "[]"))
        #expect(BoxManager.classify(record) == .foreign)
    }
}

@Suite("Create invocation")
struct RunSpecTests {

    @Test("builds the container run command appbox has always used")
    func runSpecArguments() {
        let spec = ContainerClient.RunSpec(
            name: "dev",
            image: "ubuntu:latest",
            cpus: 4,
            memory: "2G",
            volumes: [(host: "/Users/x/containers/dev/data", guest: "/data")],
            labels: ["appbox.managed": "1", "appbox.distro": "ubuntu"])

        #expect(
            spec.arguments == [
                "run", "--detach", "--name", "dev",
                "--cpus", "4", "--memory", "2G",
                "--init",
                "--volume", "/Users/x/containers/dev/data:/data",
                "--label", "appbox.distro=ubuntu",
                "--label", "appbox.managed=1",
                "ubuntu:latest",
                "sleep", "infinity",
            ])
    }
}

@Suite("Configuration")
struct ConfigurationTests {

    @Test("environment overrides are honoured")
    func environmentOverrides() {
        let config = Configuration.fromEnvironment([
            "HOME": "/Users/x",
            "APPBOX_HOME": "/tmp/boxes",
            "APPBOX_CPUS": "8",
            "APPBOX_MEMORY": "16G",
            "APPBOX_DEFAULT_DISTRO": "alpine",
        ])
        #expect(config.home.path == "/tmp/boxes")
        #expect(config.cpus == 8)
        #expect(config.memory == "16G")
        #expect(config.defaultDistro() == "alpine")
        #expect(config.dataDirectory(for: "dev").path == "/tmp/boxes/dev/data")
    }

    @Test("defaults match the bash script")
    func defaults() {
        let config = Configuration.fromEnvironment(["HOME": "/Users/x"])
        #expect(config.home.path == "/Users/x/containers")
        #expect(config.configDir.path == "/Users/x/.config/appbox")
        #expect(config.cpus == 4)
        #expect(config.memory == "2G")
        #expect(config.forcedImage == nil)
    }

    /// bash's `: "${X:=default}"` treats an empty value as unset; matching that
    /// keeps `APPBOX_IMAGE=` from forcing an empty image.
    @Test("empty environment values are treated as unset")
    func emptyValuesAreUnset() {
        let config = Configuration.fromEnvironment(["HOME": "/Users/x", "APPBOX_IMAGE": ""])
        #expect(config.forcedImage == nil)
    }

    @Test("saved default distro round-trips through disk")
    func savedDefaultRoundTrip() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let config = Configuration(home: directory, configDir: directory)

        #expect(config.defaultDistro() == nil)
        try config.saveDefaultDistro("fedora")
        #expect(config.defaultDistro() == "fedora")
        try config.clearDefaultDistro()
        #expect(config.defaultDistro() == nil)

        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("Version parsing")
struct VersionTests {

    @Test("extracts the version from container CLI output")
    func cliVersion() {
        #expect(
            ContainerClient.firstSemanticVersion(
                in: "container CLI version 1.1.0 (build: release, commit: 5973b9c)") == "1.1.0")
        #expect(
            ContainerClient.firstSemanticVersion(
                in: "apiserver.version  container-apiserver version 1.1.0 (build: release)")
                == "1.1.0")
        #expect(ContainerClient.firstSemanticVersion(in: "no version here") == nil)
    }
}
