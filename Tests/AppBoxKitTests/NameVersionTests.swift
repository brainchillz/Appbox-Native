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

    @Test("--full is extracted from any position")
    func fullFlagAnywhere() throws {
        #expect(try NameVersion.parse(["--full", "web", "24.04"]).full)
        #expect(try NameVersion.parse(["web", "--full", "24.04"]).full)
        #expect(try NameVersion.parse(["web", "24.04", "--full"]).full)
        #expect(try !NameVersion.parse(["web", "24.04"]).full)
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
