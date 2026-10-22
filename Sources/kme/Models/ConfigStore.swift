import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The single owner of config.json: loading, validation results, persistence,
/// and external-change detection. Everything that reads or writes settings goes
/// through `ConfigStore.shared`, so the settings UI, the editor, and the file on
/// disk always describe the same configuration.
///
/// Writes are patches: `update` re-reads the file, applies one change, and
/// writes the result, so a key edited by hand in the meantime is kept rather
/// than clobbered by a stale in-memory copy. A file that no longer parses is
/// never overwritten; the change applies for this session only.
final class ConfigStore {
    static var shared = ConfigStore(path: Config.defaultPath)

    let path: String
    private(set) var current: Config
    /// Problems with individual keys in the file as last loaded.
    private(set) var issues: [ConfigIssue] = []
    /// Set when the file exists but can't be used (unreadable / invalid JSON),
    /// or when the last save failed. Cleared by the next successful load/save.
    private(set) var lastError: ConfigError?
    /// The file predates the `ai` section; it's rewritten on the next save.
    private(set) var needsMigration = false
    /// mtime/size of the file as we last read or wrote it.
    private var knownStamp: FileStamp?

    private struct FileStamp: Equatable {
        let modified: Date?
        let size: Int?
    }

    init(path: String) {
        self.path = path
        self.current = Config()
        reload()
    }

    var fileExists: Bool { FileManager.default.fileExists(atPath: path) }

    // MARK: - Loading

    /// Re-read the file. On an unusable file the previous configuration stays
    /// in effect and `lastError` explains why. Returns true on success
    /// (including "no file yet", which means defaults).
    @discardableResult
    func reload() -> Bool {
        knownStamp = stamp()
        switch readDisk() {
        case .missing:
            current = Config()
            issues = []
            needsMigration = false
            lastError = nil
            return true
        case .failed(let error):
            lastError = error
            return false
        case .loaded(let decoded, _):
            current = decoded.config
            issues = decoded.issues
            needsMigration = decoded.migrated
            lastError = nil
            return true
        }
    }

    /// True when the file changed on disk since we last loaded or saved it.
    var hasChangedOnDisk: Bool { stamp() != knownStamp }

    // MARK: - Saving

    /// Apply `change` and persist it. The change is made against a fresh read of
    /// the file (patch semantics), then becomes `current`. Returns false when
    /// the change could only be applied in memory (see `lastError`).
    @discardableResult
    func update(_ change: (inout Config) -> Void) -> Bool {
        var base: Config
        var preserved: [String: Any] = [:]
        switch readDisk() {
        case .missing:
            base = current
        case .failed(let error):
            // Never overwrite a file we can't parse: the user may be mid-edit.
            change(&current)
            lastError = error
            return false
        case .loaded(let decoded, let object):
            base = decoded.config
            preserved = object
            issues = decoded.issues
        }
        change(&base)
        current = base
        return write(base, preserving: preserved)
    }

    /// Replace the configuration with defaults, keeping AI credentials and the
    /// vault history (losing an API key to a reset would be a nasty surprise).
    @discardableResult
    func resetToDefaults() -> Bool {
        update { config in
            var fresh = Config()
            fresh.ai.openRouterKey = config.ai.openRouterKey
            fresh.ai.openAIAccessToken = config.ai.openAIAccessToken
            fresh.ai.openAIRefreshToken = config.ai.openAIRefreshToken
            fresh.ai.openAIExpiresAt = config.ai.openAIExpiresAt
            fresh.recentVaults = config.recentVaults
            config = fresh
        }
    }

    /// Write the current configuration if no file exists yet (used before
    /// opening it for hand-editing, so every key is there to see).
    func materialize() {
        guard !fileExists else { return }
        _ = write(current, preserving: [:])
    }

    private func write(_ config: Config, preserving: [String: Any]) -> Bool {
        do {
            let data = try ConfigCodec.encode(config, preserving: preserving)
            try ConfigStore.atomicWrite(data, to: path)
            knownStamp = stamp()
            needsMigration = false
            lastError = nil
            return true
        } catch let error as ConfigError {
            lastError = error
        } catch {
            lastError = .writeFailed(error.localizedDescription)
        }
        return false
    }

    /// Write via a temp file in the same directory and rename it into place, so
    /// a crash can't leave a truncated config. The file keeps its existing
    /// permissions; a new one is created owner-only since it may hold API keys.
    static func atomicWrite(_ data: Data, to path: String) throws {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            throw ConfigError.writeFailed(error.localizedDescription)
        }
        let existing = (try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber
        let permissions = existing?.intValue ?? 0o600
#if os(Windows)
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw ConfigError.writeFailed(error.localizedDescription)
        }
#else
        let tmp = "\(dir)/.\((path as NSString).lastPathComponent).\(UUID().uuidString).tmp"
        guard fm.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: permissions]) else {
            throw ConfigError.writeFailed("couldn't create a temporary file in \(dir)")
        }
        if rename(tmp, path) != 0 {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(atPath: tmp)
            throw ConfigError.writeFailed(reason)
        }
#endif
    }

    // MARK: - Disk access

    private enum DiskState {
        case missing
        case failed(ConfigError)
        case loaded(ConfigCodec.Decoded, [String: Any])
    }

    private func readDisk() -> DiskState {
        guard fileExists else { return .missing }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            return .failed(.invalidJSON("unreadable: \(error.localizedDescription)"))
        }
        do {
            let object = try ConfigCodec.parseObject(data)
            return .loaded(ConfigCodec.decode(object: object), object)
        } catch let error as ConfigError {
            return .failed(error)
        } catch {
            return .failed(.invalidJSON(error.localizedDescription))
        }
    }

    private func stamp() -> FileStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return FileStamp(modified: attrs[.modificationDate] as? Date,
                         size: (attrs[.size] as? NSNumber)?.intValue)
    }
}
