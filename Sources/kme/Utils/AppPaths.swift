import Foundation

/// Where kme keeps its per-user files (config, cursor positions, glyph-width
/// cache, models).
enum AppPaths {
    static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    static func configDirectory(home: String = AppPaths.home) -> String {
        "\(home)/.config/kme"
    }

    /// The directory used before the project was renamed from editxr.
    static func legacyConfigDirectory(home: String = AppPaths.home) -> String {
        "\(home)/.config/editxr"
    }

    /// On the first run after the rename, copies `~/.config/editxr` to
    /// `~/.config/kme` so settings, cursor positions and credentials carry
    /// over. The old directory is left in place for an installed editxr. Does
    /// nothing once the new directory exists. Returns whether it copied.
    @discardableResult
    static func migrateLegacyConfigDirectory(home: String = AppPaths.home) -> Bool {
        let fm = FileManager.default
        let target = configDirectory(home: home)
        let legacy = legacyConfigDirectory(home: home)
        var isDir: ObjCBool = false
        guard !fm.fileExists(atPath: target),
              fm.fileExists(atPath: legacy, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        do {
            try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            try fm.copyItem(atPath: legacy, toPath: target)
            return true
        } catch {
            // Non-fatal: kme starts with defaults, and the old files stay intact.
            try? fm.removeItem(atPath: target)
            return false
        }
    }
}
