import XCTest

/// Real end-to-end git tests: build a temp git repo into a known state, seed a
/// `workspaces.json` pointing a session at it, launch the actual app, and assert
/// the sidebar git tokens (`git-compact`) and the title pill (`git-pill`) reflect
/// the real git state — the integration nothing else verifies (the agtCore unit
/// tests only feed canned `git status` strings to the parser).
///
/// Determinism: a restored session has no `currentCwd` until the interactive shell
/// emits OSC 7 (timing-dependent). The app refreshes git status against the session's
/// effective cwd (`currentCwd ?? initialCwd`), so the seeded `initialCwd` produces
/// git state immediately on launch/select without typing into the terminal.
///
/// Every test is gated with `XCTSkipUnless(gitAvailable())` so it skips cleanly
/// where git is absent rather than failing.
@MainActor
final class GitStatusUITests: XCTestCase {
    private var app: XCUIApplication!
    private var stateDir: URL!
    private var repos: [URL] = []

    override func setUp() async throws {
        continueAfterFailure = false
        try XCTSkipUnless(gitAvailable(), "no usable git binary found; skipping git e2e tests")
        // hermetic state: a fresh temp dir per test so the seeded workspaces.json is
        // the only state and we never touch the real one.
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agt-gituitest-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
        if let stateDir { try? FileManager.default.removeItem(at: stateDir) }
        for repo in repos { try? FileManager.default.removeItem(at: repo) }
        repos.removeAll()
    }

    // MARK: - Tests

    // a dirty work tree (one tracked file modified, uncommitted) shows the dirty
    // marker `*1` in the sidebar token.
    func testDirtyShowsDirtyMarker() throws {
        let repo = try makeRepo()
        try gitInit(repo)
        try writeFile("file.txt", "one\n", in: repo)
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "init"], in: repo)
        try writeFile("file.txt", "one\ntwo\n", in: repo) // modify tracked, leave uncommitted

        launch(seedingSessionAt: repo)

        let token = gitCompactToken()
        XCTAssertTrue(token.waitForExistence(timeout: 30),
                      "git-compact token should appear for a dirty repo")
        XCTAssertTrue(waitForValue(token, contains: "*1", timeout: 15),
                      "dirty repo should show the *1 dirty marker, got \(String(describing: token.value))")
    }

    // a clean, in-sync work tree shows no token at all (the compact string is empty,
    // so the token field is hidden — its accessibility element doesn't exist).
    func testCleanShowsNoToken() throws {
        let repo = try makeRepo()
        try gitInit(repo)
        try writeFile("file.txt", "one\n", in: repo)
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "init"], in: repo)

        launch(seedingSessionAt: repo)

        // the row must be up before we assert the absence of a token.
        XCTAssertTrue(sessionRow().waitForExistence(timeout: 30), "session row should appear")
        // give the refresh time to run, then confirm no git-compact element surfaced.
        let token = gitCompactToken()
        XCTAssertFalse(token.waitForExistence(timeout: 6),
                       "clean+synced repo should show no git-compact token, got \(String(describing: token.value))")
        // the pill, by contrast, exists for any git repo — confirm the integration ran.
        let pill = gitPill()
        XCTAssertTrue(pill.waitForExistence(timeout: 15), "clean repo should still show the branch pill")
        let pillVisible = pill.isHittable
        XCTAssertTrue(pillVisible, "the git pill must be visible (non-zero frame), not only present in the a11y tree")
        XCTAssertTrue(waitForValue(pill, contains: "main", timeout: 10),
                      "pill should show the branch name, got \(String(describing: pill.value))")
    }

    // a branch one commit ahead of its upstream shows `↑1` in the sidebar token.
    func testAheadShowsArrow() throws {
        let repo = try makeRepo()
        let remote = try makeRepo()
        try gitInit(repo)
        try writeFile("file.txt", "one\n", in: repo)
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "init"], in: repo)
        try git(["init", "--bare", remote.path], in: nil) // bare origin
        try git(["remote", "add", "origin", remote.path], in: repo)
        try git(["push", "-u", "origin", "main"], in: repo)
        // one more local commit → ahead by 1
        try writeFile("file.txt", "one\ntwo\n", in: repo)
        try git(["commit", "-am", "second"], in: repo)

        launch(seedingSessionAt: repo)

        let token = gitCompactToken()
        XCTAssertTrue(token.waitForExistence(timeout: 30),
                      "git-compact token should appear for an ahead repo")
        XCTAssertTrue(waitForValue(token, contains: "↑1", timeout: 15),
                      "ahead-by-1 repo should show ↑1, got \(String(describing: token.value))")
    }

    // a detached HEAD shows `detached @ <shortsha>` in the title pill (no ahead/behind).
    func testDetachedShowsDetachedPill() throws {
        let repo = try makeRepo()
        try gitInit(repo)
        try writeFile("file.txt", "one\n", in: repo)
        try git(["add", "."], in: repo)
        try git(["commit", "-m", "init"], in: repo)
        try writeFile("file.txt", "one\ntwo\n", in: repo)
        try git(["commit", "-am", "second"], in: repo)
        let sha = try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["checkout", sha], in: repo) // detach HEAD

        launch(seedingSessionAt: repo)

        let pill = gitPill()
        XCTAssertTrue(pill.waitForExistence(timeout: 30), "detached repo should show the pill")
        let pillVisible = pill.isHittable
        XCTAssertTrue(pillVisible, "the git pill must be visible (non-zero frame), not only present in the a11y tree")
        XCTAssertTrue(waitForValue(pill, contains: "detached @", timeout: 15),
                      "detached HEAD should show 'detached @ <sha>', got \(String(describing: pill.value))")
    }

    // MARK: - Launch + seeding

    /// Writes a `workspaces.json` into `stateDir` with one workspace and one session
    /// whose `cwd` (→ restored `initialCwd`) is `repo`, marks it selected, and launches
    /// the app pointed at `stateDir`.
    private func launch(seedingSessionAt repo: URL) {
        seedWorkspaces(sessionCwd: repo.path)
        app = XCUIApplication()
        app.launchEnvironment["AGT_STATE_DIR"] = stateDir.path
        app.launchArguments += XCUIApplication.sidebarIsolationArguments
        app.launch()
    }

    /// Hand-writes a valid `workspaces.json` matching the `Snapshot` Codable schema:
    /// top-level `version`/`selectedSessionID`/`workspaces`; each workspace `id`/`name`/
    /// `sessions`; each session `id`/`cwd` (+ optional `customName`). `selectedSessionID`
    /// is set so the session is active on launch (the pill needs an active session).
    private func seedWorkspaces(sessionCwd: String) {
        let sessionID = UUID().uuidString
        let snapshot: [String: Any] = [
            "version": 1,
            "selectedSessionID": sessionID,
            "workspaces": [
                [
                    "id": UUID().uuidString,
                    "name": "workspace 1",
                    "sessions": [
                        ["id": sessionID, "cwd": sessionCwd],
                    ],
                ],
            ],
        ]
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let data = try! JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted])
        let file = stateDir.appendingPathComponent("workspaces.json")
        try! data.write(to: file)
    }

    // MARK: - Accessibility queries

    /// The seeded session row, matched by its stable identifier (the displayed name
    /// lands in the StaticText `value`).
    private func sessionRow() -> XCUIElement { app.staticTexts["session-row"] }

    /// The sidebar git compact token, matched by `git-compact` across element types
    /// (it surfaces as a StaticText). It only exists when the compact string is
    /// non-empty (the field is hidden when clean+synced).
    private func gitCompactToken() -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "git-compact").firstMatch
    }

    /// The title-bar git pill, matched by `git-pill` across element types. It exists
    /// for any git repo (its value is the branch display).
    private func gitPill() -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "git-pill").firstMatch
    }

    /// Polls an element's `value` until it contains `needle`. A generous timeout
    /// absorbs app launch + the first git refresh tick.
    private func waitForValue(_ element: XCUIElement, contains needle: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = element.value as? String, value.contains(needle) { return true }
            usleep(200_000)
        }
        return false
    }

    // MARK: - git helpers

    /// Whether a usable git binary runs (the e2e tests need it to build repos).
    private func gitAvailable() -> Bool {
        do {
            _ = try git(["--version"], in: nil)
            return true
        } catch {
            NSLog("agt-uitest: gitAvailable() failed: %@", String(describing: error))
            return false
        }
    }

    /// Resolves a real git binary, skipping the `/usr/bin/git` shim. The shim calls
    /// `xcrun` to locate git in the active toolchain, and `xcrun` is blocked inside
    /// the App Sandbox the XCUITest runner runs in ("xcrun: error: cannot be used
    /// within an App Sandbox"), so spawning the shim here would always fail. Probes
    /// known non-shim locations (toolchain + Homebrew) and falls back to the shim
    /// (covers a machine with no Xcode where /usr/bin/git is the real binary).
    private static func resolveGitURL() -> URL {
        let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
        let candidates = [
            developerDir.map { "\($0)/usr/bin/git" },
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
        ].compactMap { $0 }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/usr/bin/git")
    }

    /// Creates a fresh temp directory tracked for teardown, used as a repo root.
    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agt-gitrepo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        repos.append(dir)
        return dir
    }

    /// `git init -b main` plus a local user identity so commits succeed regardless of
    /// the machine's global git config.
    private func gitInit(_ repo: URL) throws {
        try git(["init", "-b", "main"], in: repo)
        try git(["config", "user.email", "test@agt.local"], in: repo)
        try git(["config", "user.name", "agt test"], in: repo)
        // keep the repo independent of any ambient commit.gpgsign / hooks.
        try git(["config", "commit.gpgsign", "false"], in: repo)
    }

    /// Writes `contents` to `name` under `repo`.
    private func writeFile(_ name: String, _ contents: String, in repo: URL) throws {
        try contents.write(to: repo.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// Runs `/usr/bin/git` with `arguments` (in `cwd` when given), returns stdout, and
    /// throws on a non-zero exit so a broken fixture fails the test loudly.
    @discardableResult
    private func git(_ arguments: [String], in cwd: URL?) throws -> String {
        let process = Process()
        process.executableURL = GitStatusUITests.resolveGitURL()
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        // isolate from the user's environment so the fixtures are deterministic.
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errData, encoding: .utf8) ?? ""
            throw NSError(domain: "git", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(message)"])
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
