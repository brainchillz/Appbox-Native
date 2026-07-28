import Testing

@testable import AppBoxKit

@Suite("Order-independent name/version parsing")
struct NameVersionTests {

    @Test("version tokens are recognised")
    func versionTokens() {
        #expect(NameVersion.isVersionToken("latest"))
        #expect(NameVersion.isVersionToken("24.04"))
        #expect(NameVersion.isVersionToken("9"))
        #expect(!NameVersion.isVersionToken("web"))
        #expect(!NameVersion.isVersionToken("dev-box"))
    }

    @Test("name and version may appear in either order")
    func eitherOrder() throws {
        let forward = try NameVersion.parse(["web", "24.04"])
        let reversed = try NameVersion.parse(["24.04", "web"])
        #expect(forward == reversed)
        #expect(forward.name == "web")
        #expect(forward.version == "24.04")
    }

    @Test("--bare is extracted from any position")
    func bareFlagAnywhere() throws {
        #expect(try NameVersion.parse(["--bare", "web", "24.04"]).bare)
        #expect(try NameVersion.parse(["web", "--bare", "24.04"]).bare)
        #expect(try NameVersion.parse(["web", "24.04", "--bare"]).bare)
        #expect(try !NameVersion.parse(["web", "24.04"]).bare)
    }

    /// A full box is the default now, so the shell script's `--full` must still
    /// parse rather than being mistaken for a box name.
    @Test("--full is accepted and ignored")
    func fullFlagIsANoOp() throws {
        let parsed = try NameVersion.parse(["web", "24.04", "--full"])
        #expect(!parsed.bare)
        #expect(parsed.name == "web")
        #expect(parsed.version == "24.04")
    }

    @Test("a bare name leaves the version unset")
    func nameOnly() throws {
        let parsed = try NameVersion.parse(["web"])
        #expect(parsed.name == "web")
        #expect(parsed.version == nil)
    }

    /// Documented caveat: a box name starting with a digit is read as a
    /// version. This test exists to make that behaviour deliberate rather than
    /// accidental — if it ever changes, it should change knowingly.
    @Test("a digit-leading name is read as a version (known caveat)")
    func digitLeadingNameCaveat() throws {
        let parsed = try NameVersion.parse(["9lives"])
        #expect(parsed.version == "9lives")
        #expect(parsed.name == nil)
    }

    @Test("a third positional argument is an error")
    func tooManyArguments() {
        #expect(throws: AppBoxError.self) {
            try NameVersion.parse(["web", "24.04", "extra"])
        }
    }
}
