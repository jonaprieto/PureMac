import XCTest
@testable import PureMac

final class DevCacheSupportTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevCacheSupportTests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func make(_ relative: String, file: Bool = false) throws {
        let url = home.appendingPathComponent(relative)
        if file {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: url)
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    func testParseWorktreeListKeepsOnlyRemovableLinkedWorktrees() {
        let porcelain = """
        worktree /Users/example/repo
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        worktree /Users/example/repo-feature
        HEAD 2222222222222222222222222222222222222222
        branch refs/heads/feature/x

        worktree /Users/example/repo-detached
        HEAD 3333333333333333333333333333333333333333
        detached

        worktree /Users/example/repo-locked
        HEAD 4444444444444444444444444444444444444444
        branch refs/heads/locked
        locked in use

        worktree /Users/example/repo-gone
        HEAD 5555555555555555555555555555555555555555
        branch refs/heads/gone
        prunable gitdir file points to non-existent location

        """
        XCTAssertEqual(DevCacheSupport.parseWorktreeList(porcelain), [
            .init(path: "/Users/example/repo-feature", branch: "feature/x"),
            .init(path: "/Users/example/repo-detached", branch: nil),
        ])
    }

    func testBuildDirNeedsItsManifest() throws {
        try make("proj/Cargo.toml", file: true)
        try make("proj/target/CACHEDIR.TAG", file: true)
        try make("handmade/Cargo.toml", file: true)
        try make("handmade/target")
        try make("lean/lakefile.toml", file: true)
        try make("lean/.lake/build")
        try make("orphan/.build")

        let path = { (relative: String) in self.home.appendingPathComponent(relative).path }
        XCTAssertTrue(DevCacheSupport.isProjectBuildDir(path("proj/target")))
        XCTAssertFalse(DevCacheSupport.isProjectBuildDir(path("handmade/target")))
        XCTAssertTrue(DevCacheSupport.isProjectBuildDir(path("lean/.lake")))
        XCTAssertFalse(DevCacheSupport.isProjectBuildDir(path("orphan/.build")))
        XCTAssertFalse(DevCacheSupport.isProjectBuildDir(path("lean")))
    }

    func testRemovableBuildCacheRejectsPathsOutsidePolicy() throws {
        try make("proj/package.json", file: true)
        try make("proj/node_modules")
        let homePath = home.path

        XCTAssertTrue(DevCacheSupport.isRemovableBuildCache("\(homePath)/.cargo/registry/src", home: homePath))
        XCTAssertTrue(DevCacheSupport.isRemovableBuildCache("\(homePath)/proj/node_modules", home: homePath))
        XCTAssertFalse(DevCacheSupport.isRemovableBuildCache("\(homePath)/.cargo", home: homePath))
        XCTAssertFalse(DevCacheSupport.isRemovableBuildCache("\(homePath)/.cargo/bin", home: homePath))
        XCTAssertFalse(DevCacheSupport.isRemovableBuildCache("\(homePath)/proj", home: homePath))
        XCTAssertFalse(DevCacheSupport.isRemovableBuildCache("\(homePath)/proj/../proj/node_modules", home: homePath))
        XCTAssertFalse(DevCacheSupport.isRemovableBuildCache("/tmp/proj/node_modules", home: homePath))
    }

    func testScanProjectsFindsReposAndBuildDirsButSkipsLibrary() throws {
        try make("code/a/.git")
        try make("code/a/Package.swift", file: true)
        try make("code/a/.build/debug")
        try make("code/b/mix.exs", file: true)
        try make("code/b/_build/dev")
        try make("code/b/_build/dev/nested/.git")
        try make("Library/x/.git")
        try make("Library/x/Package.swift", file: true)
        try make("Library/x/.build")

        // The enumerator reports /private/var for temp dirs; normalize back.
        let standardize = { (path: String) in (path as NSString).standardizingPath }
        let scan = DevCacheSupport.scanProjects(home: home.path)
        XCTAssertEqual(scan.repos.map(standardize), [home.appendingPathComponent("code/a").path])
        XCTAssertEqual(Set(scan.buildDirs.map(standardize)), [
            home.appendingPathComponent("code/a/.build").path,
            home.appendingPathComponent("code/b/_build").path,
        ])
    }
}
