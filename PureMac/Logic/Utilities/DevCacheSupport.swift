import Foundation

/// Path policy for Build Caches and Stale Worktrees. ScanEngine uses it to
/// discover items and CleaningEngine re-checks every path against it before
/// deleting, so a stale or replayed item list cannot reach anything else.
enum DevCacheSupport {
    /// Global download caches that their tool refetches on demand. Caches
    /// under ~/Library/Caches are left to User Cache to avoid double counting.
    static func globalCaches(home: String) -> [(name: String, path: String)] {
        [
            ("Cargo registry sources", "\(home)/.cargo/registry/src"),
            ("Cargo registry downloads", "\(home)/.cargo/registry/cache"),
            ("Cargo git checkouts", "\(home)/.cargo/git/checkouts"),
            ("Cargo git database", "\(home)/.cargo/git/db"),
            ("Mathlib cache", "\(home)/.cache/mathlib"),
            ("uv cache", "\(home)/.cache/uv"),
            ("pre-commit cache", "\(home)/.cache/pre-commit"),
            ("Gradle caches", "\(home)/.gradle/caches"),
            ("Bun install cache", "\(home)/.bun/install/cache"),
        ]
    }

    /// Project build output directory name, mapped to the manifests one of
    /// which must sit next to it for the directory to count as rebuildable.
    static let projectBuildDirs: [String: [String]] = [
        "target": ["Cargo.toml"],
        ".lake": ["lakefile.lean", "lakefile.toml"],
        ".build": ["Package.swift"],
        "_build": ["mix.exs", "dune-project"],
        "node_modules": ["package.json"],
    ]

    /// Home subdirectories the project walk never enters.
    static let skippedHomeDirs: Set<String> = [
        "Library", "Applications", "Pictures", "Music", "Movies", "Public",
    ]

    static func isProjectBuildDir(_ path: String, fileManager: FileManager = .default) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let manifests = projectBuildDirs[url.lastPathComponent] else { return false }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        let project = url.deletingLastPathComponent()
        guard manifests.contains(where: {
            fileManager.fileExists(atPath: project.appendingPathComponent($0).path)
        }) else { return false }
        // A `target` dir next to Cargo.toml could still be hand-made; cargo
        // always drops a CACHEDIR.TAG in the ones it owns.
        if url.lastPathComponent == "target" {
            return fileManager.fileExists(atPath: url.appendingPathComponent("CACHEDIR.TAG").path)
        }
        return true
    }

    /// Clean-time check for a Build Caches item path.
    static func isRemovableBuildCache(_ path: String, home: String, fileManager: FileManager = .default) -> Bool {
        guard !path.utf8.contains(0),
              path == (path as NSString).standardizingPath,
              path.hasPrefix(home + "/") else { return false }
        if globalCaches(home: home).contains(where: { $0.path == path }) { return true }
        return isProjectBuildDir(path, fileManager: fileManager)
    }

    struct ProjectScan {
        var buildDirs: [String] = []
        var repos: [String] = []
    }

    // ponytail: depth-limited walk of non-hidden dirs under home; projects
    // nested deeper than maxDepth are missed. Add user-chosen roots if that bites.
    static func scanProjects(
        home: String,
        maxDepth: Int = 6,
        fileManager: FileManager = .default,
        onPath: (String) -> Void = { _ in }
    ) -> ProjectScan {
        var result = ProjectScan()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: home, isDirectory: true),
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return result }

        for case let url as URL in enumerator {
            if Task.isCancelled { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let name = url.lastPathComponent
            if enumerator.level == 1 && skippedHomeDirs.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            // Never descend into build outputs; node_modules alone can hold
            // hundreds of thousands of directories.
            if projectBuildDirs[name] != nil {
                enumerator.skipDescendants()
                continue
            }
            if enumerator.level >= maxDepth { enumerator.skipDescendants() }
            onPath(url.path)

            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: url.appendingPathComponent(".git").path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                result.repos.append(url.path)
            }
            for buildDir in projectBuildDirs.keys.sorted() {
                let candidate = url.appendingPathComponent(buildDir).path
                if isProjectBuildDir(candidate, fileManager: fileManager) {
                    result.buildDirs.append(candidate)
                }
            }
        }
        return result
    }

    struct Worktree: Equatable {
        let path: String
        let branch: String?
    }

    /// Linked worktrees from `git worktree list --porcelain`. Skips the main
    /// worktree (always the first block), bare, locked and prunable entries:
    /// git refuses to remove the first two and the last has nothing on disk.
    static func parseWorktreeList(_ porcelain: String) -> [Worktree] {
        let blocks = porcelain
            .components(separatedBy: "\n\n")
            .map { $0.split(separator: "\n").map(String.init) }
            .filter { !$0.isEmpty }
        return blocks.dropFirst().compactMap { lines in
            guard let pathLine = lines.first(where: { $0.hasPrefix("worktree ") }),
                  !lines.contains(where: {
                      $0 == "bare" || $0 == "locked" || $0.hasPrefix("locked ")
                          || $0 == "prunable" || $0.hasPrefix("prunable ")
                  }) else { return nil }
            let branch = lines.first(where: { $0.hasPrefix("branch ") })
                .map { String($0.dropFirst("branch refs/heads/".count)) }
            return Worktree(path: String(pathLine.dropFirst("worktree ".count)), branch: branch)
        }
    }

    /// Prefer a real git over the /usr/bin shim, which pops Apple's
    /// command-line-tools installer when no developer directory is set.
    static func gitExecutable(fileManager: FileManager = .default) -> String? {
        for candidate in ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
        where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return SimulatorRuntimeSupport.isXcrunAvailable() ? "/usr/bin/git" : nil
    }

    /// Environment for git child processes with GIT_* stripped, so a
    /// launchctl-injected GIT_DIR or GIT_WORK_TREE cannot redirect them.
    static var gitEnvironment: [String: String] {
        ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
    }

    /// Worktrees untouched this long are selected by default.
    static let staleAfter: TimeInterval = 14 * 24 * 60 * 60
}
