// fang-thumbs: an HTTP service that makes WebP previews of images, camera RAW, video and PDFs.
//
// POST /preview?path=/abs/path&width=1024&height=1024[&mime=…]  a file it can read (inside FANG_THUMBS_ROOTS)
// POST /preview?name=file.ext&width=1024&height=1024[&mime=…]   the file itself as the request body
// POST /warm   {"width":1024,"height":1024,"files":[{"path":"…","mime":"…"}]}  renders a batch in parallel and
//              keeps the results until they're fetched with /preview (answers when the batch is done)
// GET  /health
//
// Answers to /preview: 200 image/webp with Image-Width, Image-Height and X-Fang-Source headers; 403 path not
// allowed; 404 no such file; 415 unsupported format; 422 the file couldn't be rendered.

import FangThumbsCore
import Foundation
import HTTPTypes
import Hummingbird
import Logging

let environment = ProcessInfo.processInfo.environment
func setting(_ name: String) -> String? {
    guard let value = environment[name]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
    return value
}

let logger = {
    var logger = Logger(label: "fang-thumbs")
    logger.logLevel = setting("FANG_THUMBS_LOG_LEVEL").flatMap(Logger.Level.init(rawValue:)) ?? .info
    return logger
}()

let cpus = ProcessInfo.processInfo.activeProcessorCount
let memory = Int(ProcessInfo.processInfo.physicalMemory >> 30)
// Half the CPUs, and no more than fit in half the memory at 1 GB each (a 100-megapixel image or an 8K frame).
let defaultWorkers = max(1, min(cpus / 2, memory / 2, 32))
let workers = setting("FANG_THUMBS_WORKERS").flatMap(Int.init) ?? defaultWorkers
let quality = min(100, max(1, setting("FANG_THUMBS_QUALITY").flatMap(Int.init) ?? 80))
let maxUpload = (setting("FANG_THUMBS_MAX_UPLOAD_MB").flatMap(Int.init) ?? 2048) << 20
let key = setting("FANG_THUMBS_KEY")
let roots = (setting("FANG_THUMBS_ROOTS") ?? "").split(separator: ":").map(String.init)
// "from=to;from=to": paths as the caller sees them → as this container sees them.
let pathMap: [(from: String, to: String)] = (setting("FANG_THUMBS_PATH_MAP") ?? "").split(separator: ";").compactMap {
    let parts = $0.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
    return parts.count == 2 ? (parts[0], parts[1]) : nil
}
let cacheFolder = setting("FANG_THUMBS_CACHE") ?? NSTemporaryDirectory() + "fang-thumbs"
let port = setting("FANG_THUMBS_PORT").flatMap(Int.init) ?? 9000

let missing = ["vipsthumbnail", "ffmpeg", "ffprobe", "exiftool"].filter { !toolExists($0) }
if !missing.isEmpty { logger.warning("Missing tools: \(missing.joined(separator: ", ")); some formats will fail") }
let canToneMap = (try? run("ffmpeg", ["-hide_banner", "-filters"], timeout: 10))
    .map { String(decoding: $0, as: UTF8.self).contains(" zscale ") } ?? false
if !canToneMap { logger.warning("FFmpeg has no zscale filter: HDR video previews won't be tone-mapped") }

let previews = try Previews(
    settings: .init(roots: roots, pathMap: pathMap, workers: workers, cacheFolder: cacheFolder, cacheLifetime: 3600),
    renderer: Renderer(quality: quality, canToneMap: canToneMap),
    logger: logger
)

// MARK: HTTP

/// A query parameter, decoded as a form value: "+" is a space and %XX an escaped byte (Hummingbird leaves "+").
func query(_ request: Request, _ name: String) -> String? {
    guard let raw = request.uri.query else { return nil }
    for pair in raw.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == name else { continue }
        return String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
    return nil
}

func authorize(_ request: Request) throws {
    guard let key else { return }
    let bearer = request.headers[.authorization].map { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : $0 }
    guard bearer == key || query(request, "key") == key else {
        throw HTTPError(.unauthorized, message: "wrong or missing key")
    }
}

func size(_ request: Request) -> (Int, Int) {
    let width = query(request, "width").flatMap { Int($0) } ?? 1024
    let height = query(request, "height").flatMap { Int($0) } ?? width
    return (min(max(width, 16), 8192), min(max(height, 16), 8192))
}

func httpError(_ error: Error) -> HTTPError {
    switch error {
    case PreviewError.notAllowed(let path): HTTPError(.forbidden, message: "not inside FANG_THUMBS_ROOTS: \(path)")
    case PreviewError.notFound(let path): HTTPError(.notFound, message: "no such file: \(path)")
    case PreviewError.unsupported(let name): HTTPError(.unsupportedMediaType, message: "unsupported format: \(name)")
    case PreviewError.failed(let reason): HTTPError(.unprocessableContent, message: reason)
    case let error as HTTPError: error
    default: HTTPError(.internalServerError, message: "\(error)")
    }
}

func answer(_ preview: Preview) -> Response {
    var headers = HTTPFields()
    headers[.contentType] = "image/webp"
    headers[HTTPField.Name("Image-Width")!] = String(preview.width)
    headers[HTTPField.Name("Image-Height")!] = String(preview.height)
    headers[HTTPField.Name("X-Fang-Source")!] = preview.source.rawValue
    return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: preview.data)))
}

struct WarmRequest: Decodable {
    struct File: Decodable {
        var path: String
        var mime: String?
    }
    var width: Int?
    var height: Int?
    var files: [File]
}

struct WarmResult: Encodable {
    var path: String
    var ok: Bool
    var error: String?
}

struct WarmResponse: ResponseEncodable {
    var results: [WarmResult]
}

struct Health: ResponseEncodable {
    var ok = true
    var workers: Int
    var busy: Int
    var queued: Int
    var quality: Int
    var toneMapping: Bool
    var missingTools: [String]
    var pathAccess: Bool
}

let router = Router()

router.get("/health") { _, _ in
    Health(workers: workers, busy: await previews.busy, queued: await previews.queued, quality: quality,
           toneMapping: canToneMap, missingTools: missing, pathAccess: !roots.isEmpty)
}

router.post("/preview") { request, _ -> Response in
    try authorize(request)
    let (width, height) = size(request)
    let mime = query(request, "mime")
    let started = Date()
    do {
        if let path = query(request, "path") {
            let file = try previews.locate(path, mimeType: mime, width: width, height: height)
            let preview = try await previews.preview(of: file, width: width, height: height)
            logger.debug("\(file.path): \(preview.source.rawValue), \(preview.data.count) bytes in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            return answer(preview)
        }
        // The file itself in the body.
        let name = query(request, "name") ?? ""
        let given = (name as NSString).pathExtension.lowercased()
        guard let kind = Formats.kind(extension: given, mimeType: mime) else {
            throw PreviewError.unsupported(name.isEmpty ? (mime ?? "file") : name)
        }
        let ext = given.isEmpty || Formats.kind(extension: given, mimeType: nil) == nil
            ? Formats.fallbackExtension(for: kind) : given
        let folder = try previews.uploadFolder()
        do {
            let handle = try FileHandle(forWritingTo: {
                let url = URL(fileURLWithPath: folder + "/input." + ext)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                return url
            }())
            var written = 0
            for try await buffer in request.body {
                written += buffer.readableBytes
                guard written <= maxUpload else {
                    try? handle.close()
                    throw HTTPError(.contentTooLarge, message: "larger than FANG_THUMBS_MAX_UPLOAD_MB")
                }
                try handle.write(contentsOf: Data(buffer.readableBytesView))
            }
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(atPath: folder)
            throw error
        }
        let preview = try await previews.renderUpload(folder: folder, ext: ext, kind: kind, width: width, height: height)
        logger.debug("upload \(name): \(preview.source.rawValue), \(preview.data.count) bytes in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return answer(preview)
    } catch {
        let failure = httpError(error)
        if failure.status == .unprocessableContent || failure.status == .internalServerError {
            logger.info("preview failed: \(failure.body ?? "")")
        }
        throw failure
    }
}

router.post("/warm") { request, context -> WarmResponse in
    try authorize(request)
    let batch = try await request.decode(as: WarmRequest.self, context: context)
    let width = min(max(batch.width ?? 1024, 16), 8192), height = min(max(batch.height ?? batch.width ?? 1024, 16), 8192)
    let started = Date()
    let results = await withTaskGroup(of: (Int, WarmResult).self) { group in
        for (index, file) in batch.files.enumerated() {
            group.addTask {
                do {
                    let located = try previews.locate(file.path, mimeType: file.mime, width: width, height: height)
                    try await previews.warm(located, width: width, height: height)
                    return (index, WarmResult(path: file.path, ok: true))
                } catch {
                    return (index, WarmResult(path: file.path, ok: false, error: httpError(error).body))
                }
            }
        }
        var results = [WarmResult?](repeating: nil, count: batch.files.count)
        for await (index, result) in group { results[index] = result }
        return results.compactMap { $0 }
    }
    let failed = results.filter { !$0.ok }.count
    logger.info("warmed \(results.count - failed) of \(results.count) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
    return WarmResponse(results: results)
}

var configuration = ApplicationConfiguration(address: .hostname("0.0.0.0", port: port), serverName: "fang-thumbs")
let app = Application(router: router, configuration: configuration, logger: logger)
logger.info("fang-thumbs on port \(port): \(workers) workers, WebP quality \(quality), \(roots.isEmpty ? "uploads only" : "reads \(roots.joined(separator: ", "))")")
try await app.runService()
