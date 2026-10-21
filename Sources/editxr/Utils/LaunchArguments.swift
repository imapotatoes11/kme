import Foundation

/// Decides how an `editxr` invocation starts from its command-line arguments.
/// Pure (no side effects) so the launch rules are unit-testable; `main.swift`
/// applies the result (pinning the vault root and starting the app).
enum LaunchArguments {

    /// What an invocation asked for.
    struct Parse {
        /// Paths to open as documents, in argument order. Never contains the
        /// directory that became `directoryRoot`.
        let filePaths: [String]
        /// A positional argument that named a directory (e.g. `editxr .`): it
        /// becomes the project root the file-explorer sidebar scans. Nil when
        /// no directory argument was given, or `--vault` pinned the root.
        let directoryRoot: String?
        /// True when `--vault` was passed with no value: open the configured
        /// vault (the folder in the config) rather than a one-off root.
        let openVault: Bool
    }

    /// Classify the arguments. `vaultArgIndex` is the argument offset of the
    /// `--vault` value, or nil when there is none; an explicit `--vault` takes
    /// precedence over a positional directory, so with one present a directory
    /// argument keeps the historical "open it as a file" treatment.
    ///
    /// A bare `--vault` (present but with no value) sets `openVault`: the
    /// configured vault is opened later, once the config has been read.
    static func parse(arguments: [String], vaultArgIndex: Int?) -> Parse {
        let fm = FileManager.default
        var filePaths: [String] = []
        var directoryRoot: String? = nil
        let openVault = vaultArgIndex == nil && arguments.contains("--vault")

        for (i, arg) in arguments.enumerated()
            where i > 0 && i != vaultArgIndex && !arg.hasPrefix("-") {
            var isDir: ObjCBool = false
            if vaultArgIndex == nil, directoryRoot == nil,
               fm.fileExists(atPath: arg, isDirectory: &isDir), isDir.boolValue {
                directoryRoot = Vault.standardized(arg)
            } else {
                filePaths.append(arg)
            }
        }
        return Parse(filePaths: filePaths, directoryRoot: directoryRoot, openVault: openVault)
    }

    /// Build the tabs an invocation opens. Opening a directory with no file
    /// (e.g. `editxr .`) opens the project's primary file instead — a root
    /// README if there is one, else the first editable file — so the tab starts
    /// with real content. Whenever a directory was passed, every tab starts
    /// with the file-explorer sidebar on; that is run-scoped and does not
    /// rewrite the saved preference.
    ///
    /// A bare `--vault` behaves the same way against `vaultRoot` (the configured
    /// vault, resolved by the caller). When no vault is configured the caller
    /// passes nil and this returns no states, so `main` falls back to help.
    static func makeStates(from parse: Parse, vaultRoot: String? = nil) -> [EditorState] {
        var filePaths = parse.filePaths
        var root = parse.directoryRoot

        if parse.openVault {
            guard let vaultRoot, !vaultRoot.isEmpty else { return [] }
            root = vaultRoot
        }

        if filePaths.isEmpty, let root {
            if let primary = DirectoryScanner.primaryFile(in: DirectoryScanner.scan(root: root)) {
                filePaths.append(root + "/" + primary)
            } else {
                filePaths.append(root)   // empty directory: lone empty buffer
            }
        }

        let states = filePaths.map { EditorState(filePath: $0) }
        if root != nil {
            for st in states { st.sidebarMode = .files }
        }
        return states
    }
}
