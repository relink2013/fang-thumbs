import Crypto
import Foundation
import Logging
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A finished preview.
public struct Preview: Sendable {
    public var data: Data
    public var width: Int
    public var height: Int
    public var source: Renderer.Source
}

public enum PreviewError: Error, Sendable {
    /// The path is outside the folders this service may read (403).
    case notAllowed(String)
    /// No such file (404).
    case notFound(String)
    /// Not a format this service renders (415).
    case unsupported(String)
    /// The tools couldn't render it (422).
    case failed(String)
}

/// Renders previews of files on disk with a fixed number of workers, so a burst of requests (a batch warm-up,
/// a folder opened in a browser) queues instead of starting hundreds of tools at once. Two requests for the
/// same preview share one render. Results of a warm-up are kept for a while in the cache folder, until the
/// preview is asked for.
public actor Previews {
    public struct Settings: Sendable {
        /// Folders whose files may be read by path. Empty: only uploaded files are rendered.
        public var roots: [String]
        /// Path prefixes to rewrite before reading (as the caller sees them → as this service sees them).
        public var pathMap: [(from: String, to: String)]
        public var workers: Int
        public var cacheFolder: String
        /// How long a warmed-up preview waits to be fetched.
        public var cacheLifetime: TimeInterval

        public init(roots: [String], pathMap: [(from: String, to: String)], workers: Int, cacheFolder: String,
                    cacheLifetime: TimeInterval) {
            self.roots = roots
            self.pathMap = pathMap
            self.workers = workers
            self.cacheFolder = cacheFolder
            self.cacheLifetime = cacheLifetime
        }
    }

    public nonisolated let settings: Settings
    nonisolated let renderer: Renderer
    nonisolated let logger: Logger
    private var running: [String: Task<Preview, Error>] = [:]
    private var idle: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var lastSweep = Date()
    /// The roots with links resolved, like the paths compared with them.
    nonisolated let resolvedRoots: [String]

    public init(settings: Settings, renderer: Renderer, logger: Logger) throws {
        self.settings = settings
        self.renderer = renderer
        self.logger = logger
        self.idle = settings.workers
        self.resolvedRoots = settings.roots.map { root in
            guard let real = realpath(root, nil) else { return root }
            defer { Foundation.free(real) }
            return String(cString: real)
        }
        try FileManager.default.createDirectory(atPath: settings.cacheFolder + "/ready", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: settings.cacheFolder + "/work", withIntermediateDirectories: true)
        // Leftovers from an earlier run.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: settings.cacheFolder + "/work")) ?? [] {
            try? FileManager.default.removeItem(atPath: settings.cacheFolder + "/work/" + name)
        }
    }

    // MARK: Files by path

    /// A file this service may read: the real path (links resolved) and what identifies its contents.
    public struct Located: Sendable {
        public var path: String
        public var ext: String
        public var kind: Kind
        public var key: String
    }

    public nonisolated func locate(_ requested: String, mimeType: String?, width: Int, height: Int) throws -> Located {
        var path = requested
        for (from, to) in settings.pathMap where path == from || path.hasPrefix(from.hasSuffix("/") ? from : from + "/") {
            path = to + path.dropFirst(from.count)
            break
        }
        guard path.hasPrefix("/"), let real = realpath(path, nil) else { throw PreviewError.notFound(requested) }
        let resolved = String(cString: real)
        free(real)
        let allowed = resolvedRoots.contains { root in
            let root = root.hasSuffix("/") ? String(root.dropLast()) : root
            return root.isEmpty || resolved == root || resolved.hasPrefix(root + "/")
        }
        guard allowed else { throw PreviewError.notAllowed(requested) }
        var info = stat()
        guard stat(resolved, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw PreviewError.notFound(requested) }
        let name = (resolved as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        guard let kind = Formats.kind(extension: ext, mimeType: mimeType) else { throw PreviewError.unsupported(name) }
        #if canImport(Darwin)
        let mtime = Int(info.st_mtimespec.tv_sec), nanos = Int(info.st_mtimespec.tv_nsec)
        #else
        let mtime = Int(info.st_mtim.tv_sec), nanos = Int(info.st_mtim.tv_nsec)
        #endif
        let identity = "\(resolved)\n\(info.st_size)\n\(mtime).\(nanos)\n\(width)x\(height)\n\(renderer.quality)"
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return Located(path: resolved, ext: ext.isEmpty ? Formats.fallbackExtension(for: kind) : ext, kind: kind, key: key)
    }

    /// The preview of a file on disk: a warmed-up one if it's waiting (then it's removed), else rendered now.
    public func preview(of file: Located, width: Int, height: Int) async throws -> Preview {
        let ready = settings.cacheFolder + "/ready/" + file.key + ".webp"
        if running[file.key] == nil, let data = FileManager.default.contents(atPath: ready), let size = webpSize(data) {
            try? FileManager.default.removeItem(atPath: ready)
            let source = (try? String(contentsOfFile: ready + ".source", encoding: .utf8)).flatMap(Renderer.Source.init) ?? .rendered
            try? FileManager.default.removeItem(atPath: ready + ".source")
            return Preview(data: data, width: size.width, height: size.height, source: source)
        }
        let preview = try await shared(file.key) { [renderer, settings] in
            try Self.render(file.path, link: true, kind: file.kind, ext: file.ext, width: width, height: height,
                            renderer: renderer, work: settings.cacheFolder + "/work")
        }
        // A warm-up running at the same time stored it too: this request has it now.
        try? FileManager.default.removeItem(atPath: ready)
        try? FileManager.default.removeItem(atPath: ready + ".source")
        return preview
    }

    /// Renders a file on disk and keeps the result in the cache folder for a later `preview(of:)`.
    public func warm(_ file: Located, width: Int, height: Int) async throws {
        let ready = settings.cacheFolder + "/ready/" + file.key + ".webp"
        if FileManager.default.fileExists(atPath: ready) { return }
        let preview = try await shared(file.key) { [renderer, settings] in
            try Self.render(file.path, link: true, kind: file.kind, ext: file.ext, width: width, height: height,
                            renderer: renderer, work: settings.cacheFolder + "/work")
        }
        let temporary = ready + ".part"
        try preview.data.write(to: URL(fileURLWithPath: temporary))
        try? preview.source.rawValue.write(toFile: ready + ".source", atomically: true, encoding: .utf8)
        _ = rename(temporary, ready)
        sweepIfDue()
    }

    // MARK: Uploaded files

    /// A folder for an upload to be written into; `renderUpload` removes it.
    public nonisolated func uploadFolder() throws -> String {
        let folder = settings.cacheFolder + "/work/" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Renders a file that was uploaded into `folder` as `input.<ext>`.
    public func renderUpload(folder: String, ext: String, kind: Kind, width: Int, height: Int) async throws -> Preview {
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let input = folder + "/input." + ext
        return try await limited { [renderer] in
            try Self.render(input, link: false, kind: kind, ext: ext, width: width, height: height,
                            renderer: renderer, work: folder)
        }
    }

    // MARK: Workers

    /// Runs `body` once for concurrent requests of the same key.
    private func shared(_ key: String, _ body: @escaping @Sendable () throws -> Preview) async throws -> Preview {
        if let task = running[key] { return try await task.value }
        let task = Task { try await self.limited(body) }
        running[key] = task
        defer { running[key] = nil }
        return try await task.value
    }

    /// Runs `body` on its own thread when a worker is free.
    private func limited(_ body: @escaping @Sendable () throws -> Preview) async throws -> Preview {
        if idle > 0 {
            idle -= 1
        } else {
            await withCheckedContinuation { waiting.append($0) }
        }
        defer {
            if waiting.isEmpty { idle += 1 } else { waiting.removeFirst().resume() }
        }
        return try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    public var queued: Int { waiting.count }
    public var busy: Int { settings.workers - idle }

    // MARK: Rendering

    static func render(_ path: String, link: Bool, kind: Kind, ext: String, width: Int, height: Int,
                       renderer: Renderer, work: String) throws -> Preview {
        let scratch = link ? work + "/" + UUID().uuidString : work + "/render"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        // The tools see "input.<ext>": file names with brackets, colons or a leading dash can't be
        // misread as options, and every tool picks its reader from a plain extension.
        var input = path
        if link {
            input = scratch + "/input." + ext
            try FileManager.default.createSymbolicLink(atPath: input, withDestinationPath: path)
        }
        let output = scratch + "/preview.webp"
        do {
            let source = try renderer.render(input, kind: kind, ext: ext, width: width, height: height,
                                             to: output, scratch: scratch)
            guard let data = FileManager.default.contents(atPath: output), let size = webpSize(data) else {
                throw PreviewError.failed("no preview was written")
            }
            return Preview(data: data, width: size.width, height: size.height, source: source)
        } catch let error as ToolError {
            throw PreviewError.failed(error.description)
        }
    }

    /// Removes warmed-up previews nobody fetched.
    private func sweepIfDue() {
        guard Date().timeIntervalSince(lastSweep) > 300 else { return }
        lastSweep = Date()
        let folder = settings.cacheFolder + "/ready"
        let limit = Date().addingTimeInterval(-settings.cacheLifetime)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
            let path = folder + "/" + name
            if let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date, date < limit {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }
}
