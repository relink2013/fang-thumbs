import Foundation
import Logging
import Testing
@testable import FangThumbsCore

@Suite struct FormatsTests {
    @Test func kinds() {
        #expect(Formats.kind(extension: "DNG", mimeType: nil) == .raw)
        #expect(Formats.kind(extension: "mov", mimeType: nil) == .video)
        #expect(Formats.kind(extension: "heic", mimeType: nil) == .image)
        #expect(Formats.kind(extension: "pdf", mimeType: nil) == .document)
        #expect(Formats.kind(extension: "v1769529388", mimeType: "video/mp4") == .video)
        #expect(Formats.kind(extension: "", mimeType: "image/x-dcraw") == .raw)
        #expect(Formats.kind(extension: "txt", mimeType: "text/plain") == nil)
    }
}

/// End-to-end renders with the real tools, on files made here. Skipped where the tools aren't installed.
@Suite(.enabled(if: toolExists("vipsthumbnail") && toolExists("ffmpeg") && toolExists("exiftool")))
struct RenderTests {
    let folder: String
    let previews: Previews

    init() throws {
        folder = NSTemporaryDirectory() + "fang-thumbs-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder + "/files", withIntermediateDirectories: true)
        previews = try Previews(
            settings: .init(roots: [folder + "/files"], pathMap: [("/nextcloud/data", folder + "/files")], workers: 4,
                            cacheFolder: folder + "/cache", cacheLifetime: 3600),
            renderer: Renderer(quality: 80, canToneMap: false),
            logger: Logger(label: "test"))
    }

    func make(_ name: String, _ tool: String, _ arguments: [String]) throws -> String {
        let path = folder + "/files/" + name
        try run(tool, arguments.map { $0.replacingOccurrences(of: "OUT", with: path) })
        return path
    }

    func preview(_ path: String, width: Int = 512) async throws -> Preview {
        let file = try previews.locate(path, mimeType: nil, width: width, height: width)
        return try await previews.preview(of: file, width: width, height: width)
    }

    @Test func jpegIsShrunkNotEnlarged() async throws {
        let big = try make("big [1].jpg", "vips", ["black", "OUT", "3000", "2000"])
        let small = try make("small.png", "vips", ["black", "OUT", "200", "100"])
        let a = try await preview(big)
        #expect((a.width, a.height) == (512, 341))
        #expect(a.source == .rendered)
        let b = try await preview(small)
        #expect((b.width, b.height) == (200, 100))
    }

    @Test func heic() async throws {
        let path = try make("photo.heic", "vips", ["black", "OUT", "1600", "1200"])
        let p = try await preview(path)
        #expect((p.width, p.height) == (512, 384))
    }

    @Test func svg() async throws {
        let path = folder + "/files/drawing.svg"
        try #"<svg xmlns="http://www.w3.org/2000/svg" width="400" height="200"><rect width="400" height="200" fill="red"/></svg>"#
            .write(toFile: path, atomically: true, encoding: .utf8)
        let p = try await preview(path)
        #expect((p.width, p.height) == (400, 200))
    }

    @Test func proResVideo() async throws {
        let path = try make("clip.mov", "ffmpeg", ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=24:duration=3",
                                                   "-c:v", "prores_ks", "-profile:v", "3", "-y", "OUT"])
        let p = try await preview(path)
        #expect((p.width, p.height) == (512, 288))
        #expect(p.source == .video)
    }

    @Test func rawUsesEmbeddedPreview() async throws {
        // A stand-in "RAW": a small image carrying a larger embedded preview, the way RAW files carry theirs.
        let embedded = try make("preview.jpg", "vips", ["black", "OUT", "600", "400"])
        let small = try make("shot.jpg", "vips", ["black", "OUT", "64", "64"])
        try run("exiftool", ["-q", "-overwrite_original", "-ThumbnailImage<=\(embedded)", small])
        let raw = folder + "/files/shot.dng"
        try FileManager.default.moveItem(atPath: small, toPath: raw)
        let p = try await preview(raw)
        #expect(p.source == .embedded)
        #expect((p.width, p.height) == (512, 341))
    }

    @Test func tinyEmbeddedPreviewIsNotUsed() async throws {
        // Only a thumbnail-sized preview embedded, but the file itself can be rendered: render it.
        let tiny = try make("tiny.jpg", "vips", ["gaussnoise", "OUT", "160", "107"])
        let body = try make("big.jpg", "vips", ["black", "OUT", "1200", "800"])
        try run("exiftool", ["-q", "-overwrite_original", "-ThumbnailImage<=\(tiny)", body])
        let psd = folder + "/files/big.psd"
        try FileManager.default.moveItem(atPath: body, toPath: psd)
        let p = try await preview(psd)
        #expect(p.source == .rendered)
        #expect((p.width, p.height) == (512, 341))
    }

    @Test func pathRulesAndMapping() async throws {
        _ = try make("mapped.jpg", "vips", ["black", "OUT", "100", "100"])
        let p = try await preview("/nextcloud/data/mapped.jpg")
        #expect(p.width == 100)
        #expect(throws: PreviewError.self) { try previews.locate("/etc/hosts", mimeType: nil, width: 64, height: 64) }
        #expect(throws: PreviewError.self) {
            try previews.locate(folder + "/files/../cache", mimeType: nil, width: 64, height: 64)
        }
    }

    @Test func warmThenFetch() async throws {
        let path = try make("warm.jpg", "vips", ["black", "OUT", "900", "900"])
        let file = try previews.locate(path, mimeType: nil, width: 256, height: 256)
        try await previews.warm(file, width: 256, height: 256)
        #expect(FileManager.default.fileExists(atPath: folder + "/cache/ready/\(file.key).webp"))
        let p = try await previews.preview(of: file, width: 256, height: 256)
        #expect(p.width == 256)
        #expect(!FileManager.default.fileExists(atPath: folder + "/cache/ready/\(file.key).webp"))
    }

    @Test func parallelBatch() async throws {
        let paths = try (0..<12).map { try make("batch-\($0).jpg", "vips", ["black", "OUT", "2000", "1500"]) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for path in paths {
                group.addTask {
                    let file = try previews.locate(path, mimeType: nil, width: 256, height: 256)
                    try await previews.warm(file, width: 256, height: 256)
                }
            }
            try await group.waitForAll()
        }
        #expect(await previews.busy == 0)
    }
}

@Suite struct WebPHeaderTests {
    @Test(.enabled(if: toolExists("vips"))) func lossyAndLossless() throws {
        let folder = NSTemporaryDirectory() + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try run("vips", ["black", folder + "/a.webp[Q=80]", "321", "123"])
        try run("vips", ["black", folder + "/b.webp[lossless]", "77", "4000"])
        #expect(webpSize(try Data(contentsOf: URL(fileURLWithPath: folder + "/a.webp")))! == (321, 123))
        #expect(webpSize(try Data(contentsOf: URL(fileURLWithPath: folder + "/b.webp")))! == (77, 4000))
    }
}
