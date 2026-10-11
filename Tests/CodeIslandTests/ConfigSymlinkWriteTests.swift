import XCTest
@testable import CodeIsland
import CodeIslandCore

/// Hook writes through symlinked config files. Multi-account and dotfiles
/// setups link `hooks.json` / `config.toml` to a shared copy; an atomic
/// replace used to turn the link into a detached regular file on the first
/// write. Everything runs in a temporary directory, with `CODEX_HOME` pointed
/// into it for the primary-root cases.
final class ConfigSymlinkWriteTests: XCTestCase {
    private var sandbox: String!
    private var savedCodexHome: String?
    private let fm = FileManager.default

    override func setUpWithError() throws {
        sandbox = fm.temporaryDirectory.appendingPathComponent("config-symlink-writes-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: sandbox + "/dotfiles", withIntermediateDirectories: true)
        savedCodexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
    }

    override func tearDownWithError() throws {
        if let savedCodexHome {
            setenv("CODEX_HOME", savedCodexHome, 1)
        } else {
            unsetenv("CODEX_HOME")
        }
        try? fm.removeItem(atPath: sandbox)
    }

    private func makeDir(_ relative: String, files: [String] = []) throws -> String {
        let path = sandbox + "/" + relative
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        for file in files { XCTAssertTrue(fm.createFile(atPath: path + "/" + file, contents: Data("{}".utf8))) }
        return path
    }

    /// `link` → `sandbox/dotfiles/<name>` holding `contents`; returns the target.
    @discardableResult
    private func linkToDotfile(_ link: String, named name: String, contents: String) throws -> String {
        let target = sandbox + "/dotfiles/" + name
        XCTAssertTrue(fm.createFile(atPath: target, contents: Data(contents.utf8)))
        try fm.createSymbolicLink(atPath: link, withDestinationPath: target)
        return target
    }

    private func isSymlink(_ path: String) -> Bool {
        (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private func hooks(inJSONAt path: String) throws -> [String: Any] {
        let data = try XCTUnwrap(fm.contents(atPath: path))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return root["hooks"] as? [String: Any] ?? [:]
    }

    // MARK: - Extra roots

    func testCodexExtraRootKeepsItsSymlinkedHooksFile() throws {
        let root = try makeDir("codex-work", files: ["auth.json"])
        let hooksTarget = try linkToDotfile(root + "/hooks.json", named: "codex-hooks.json", contents: "{}\n")
        let cli = try XCTUnwrap(ConfigInstaller.extraConfigDirCLI(for: ExtraConfigDir(cli: .codex, path: root)))

        XCTAssertEqual(ConfigInstaller.installHooks(inExtraDir: cli, fm: fm, primaryRoot: sandbox + "/primary", peers: []), .installed)

        XCTAssertTrue(isSymlink(root + "/hooks.json"), "hooks.json is still the shared link")
        XCTAssertNotNil(try hooks(inJSONAt: hooksTarget)["Stop"], "the hooks landed in the linked file")

        // A second install (Codex rewrites hooks.json every time) keeps it too.
        XCTAssertEqual(ConfigInstaller.installHooks(inExtraDir: cli, fm: fm, primaryRoot: sandbox + "/primary", peers: []), .installed)
        XCTAssertTrue(isSymlink(root + "/hooks.json"))
    }

    // MARK: - Primary root (the same write paths)

    /// The primary Codex entry, rooted at `$CODEX_HOME`: before the fix its
    /// hooks.json symlink was replaced by a copy as well. Its config.toml is
    /// never written, so a user's `hooks = false` stays theirs.
    func testPrimaryCodexRootKeepsItsSymlinkedFiles() throws {
        let home = try makeDir("codex")
        setenv("CODEX_HOME", home, 1)
        let hooksTarget = try linkToDotfile(home + "/hooks.json", named: "primary-hooks.json", contents: "{}\n")
        let configTarget = try linkToDotfile(home + "/config.toml", named: "primary-config.toml", contents: "[features]\nhooks = false\n")
        let primary = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "codex" })
        XCTAssertEqual(primary.fullPath, home + "/hooks.json")

        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: primary, fm: fm))
        XCTAssertTrue(isSymlink(home + "/hooks.json"))
        XCTAssertNotNil(try hooks(inJSONAt: hooksTarget)["Stop"])
        XCTAssertEqual(try String(contentsOfFile: configTarget, encoding: .utf8), "[features]\nhooks = false\n")

        ConfigInstaller.uninstallHooks(cli: primary, fm: fm)
        XCTAssertTrue(isSymlink(home + "/hooks.json"))
        XCTAssertTrue(try hooks(inJSONAt: hooksTarget).isEmpty)
    }

    /// A regular (non-symlinked) primary file is still replaced in place —
    /// the only behaviour change is for symlinks.
    func testPrimaryRegularFileIsWrittenInPlaceAsBefore() throws {
        let home = try makeDir("codex-plain")
        setenv("CODEX_HOME", home, 1)
        let primary = try XCTUnwrap(ConfigInstaller.allCLIs.first { $0.source == "codex" })

        XCTAssertTrue(ConfigInstaller.installExternalHooks(cli: primary, fm: fm))
        XCTAssertFalse(isSymlink(home + "/hooks.json"))
        XCTAssertNotNil(try hooks(inJSONAt: home + "/hooks.json")["Stop"])
    }

}
