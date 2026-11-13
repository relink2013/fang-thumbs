import Foundation

/// Makes one WebP preview of one file. Stateless: every call works in its own scratch folder.
public struct Renderer: Sendable {
    /// WebP quality, 1–100.
    public var quality: Int
    /// HDR video is tone-mapped only when FFmpeg has zscale (libzimg).
    public var canToneMap: Bool

    public init(quality: Int, canToneMap: Bool) {
        self.quality = quality
        self.canToneMap = canToneMap
    }

    /// What a render used, for logs and the `X-Fang-Source` header.
    public enum Source: String, Sendable {
        case embedded, rendered, video
    }

    /// Renders `input` (a file named with its real extension, inside or linked into `scratch`) into `output`,
    /// fitting inside width × height, never enlarged.
    public func render(_ input: String, kind: Kind, ext: String, width: Int, height: Int,
                       to output: String, scratch: String) throws -> Source {
        switch kind {
        case .video:
            try renderVideo(input, width: width, height: height, to: output, scratch: scratch)
            return .video
        case .raw:
            return try embeddedFirst(input, width: width, height: height, to: output, scratch: scratch)
        case .document:
            try renderImage(input, width: width, height: height, to: output)
            return .rendered
        case .image:
            if ext == "icns" {
                try renderIcon(input, width: width, height: height, to: output, scratch: scratch)
                return .rendered
            }
            if ext == "psd" || ext == "psb" {
                return try embeddedFirst(input, width: width, height: height, to: output, scratch: scratch)
            }
            do {
                try renderImage(input, width: width, height: height, to: output)
                return .rendered
            } catch {
                // Some files libvips can't open still carry a preview.
                let embedded = scratch + "/embedded.jpg"
                guard extractEmbedded(input, to: embedded) else { throw error }
                try renderImage(embedded, width: width, height: height, to: output)
                return .embedded
            }
        }
    }

    /// RAW and Photoshop files: the embedded preview when it's big enough (at least half the requested size,
    /// capped at 512 px), else a render of the file itself, else whatever preview is embedded.
    func embeddedFirst(_ input: String, width: Int, height: Int, to output: String, scratch: String) throws -> Source {
        let embedded = scratch + "/embedded.jpg"
        let hasEmbedded = extractEmbedded(input, to: embedded)
        if hasEmbedded, let size = imageSize(embedded), max(size.width, size.height) >= min(max(width, height) / 2, 512),
           (try? renderImage(embedded, width: width, height: height, to: output)) != nil {
            return .embedded
        }
        do {
            try renderImage(input, width: width, height: height, to: output)
            return .rendered
        } catch {
            guard hasEmbedded else { throw error }
            try renderImage(embedded, width: width, height: height, to: output)
            return .embedded
        }
    }

    /// Width and height of an image file, from its header.
    func imageSize(_ path: String) -> (width: Int, height: Int)? {
        guard let output = try? run("vipsheader", ["-f", "width", "-f", "height", path], timeout: 30) else { return nil }
        let numbers = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        return numbers.count >= 2 ? (numbers[0], numbers[1]) : nil
    }

    /// A still image to WebP: shrink-on-load, sRGB, EXIF orientation applied, metadata dropped, never enlarged.
    func renderImage(_ input: String, width: Int, height: Int, to output: String) throws {
        try run("vipsthumbnail", [input, "--size", "\(width)x\(height)>", "--export-profile", "srgb",
                                  "-o", "\(output)[Q=\(quality),strip,effort=4]"])
    }

    /// The largest preview embedded in the file, written to `output` with the file's orientation; false if none.
    func extractEmbedded(_ input: String, to output: String) -> Bool {
        let tags = ["JpgFromRaw", "PreviewImage", "OtherImage", "PhotoshopThumbnail", "ThumbnailImage"]
        // One call lists which previews exist and how big they are ("(Binary data 123 bytes, …)").
        guard let listing = try? run("exiftool", ["-j", "-q"] + tags.map { "-\($0)" } + [input], timeout: 60),
              let entries = try? JSONSerialization.jsonObject(with: listing) as? [[String: Any]],
              let entry = entries.first
        else { return false }
        func bytes(_ tag: String) -> Int {
            guard let text = entry[tag] as? String, let range = text.range(of: #"\d+ bytes"#, options: .regularExpression)
            else { return 0 }
            return Int(text[range].dropLast(6)) ?? 0
        }
        guard let tag = tags.filter({ bytes($0) > 1024 }).max(by: { bytes($0) < bytes($1) }),
              let data = try? run("exiftool", ["-b", "-\(tag)", input], timeout: 60), data.count > 1024,
              FileManager.default.createFile(atPath: output, contents: data)
        else { return false }
        // Embedded previews usually lack the orientation: copy it from the file, so the render turns it upright.
        _ = try? run("exiftool", ["-q", "-overwrite_original", "-TagsFromFile", input, "-Orientation", output], timeout: 60)
        return true
    }

    /// A representative frame (FFmpeg's thumbnail filter over the first frames after a short seek), HDR
    /// tone-mapped to SDR, then encoded like a still image so every preview comes out the same way.
    func renderVideo(_ input: String, width: Int, height: Int, to output: String, scratch: String) throws {
        let probe = String(decoding: try run("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries",
                                                         "format=duration:stream=color_transfer,codec_type",
                                                         "-of", "default=nw=1", input], timeout: 60), as: UTF8.self)
        guard probe.contains("codec_type=video") else { throw ToolError("no video track (sound only)") }
        var duration = 0.0, transfer = ""
        for line in probe.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0] == "duration" { duration = Double(parts[1]) ?? 0 }
            if parts[0] == "color_transfer" { transfer = parts[1] }
        }
        // HDR (PQ or HLG, as iPhones record) looks washed out unless it's tone-mapped.
        let toneMap = canToneMap && ["smpte2084", "arib-std-b67"].contains(transfer)
            ? "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p,"
            : ""
        let seek = duration > 2 ? min(duration * 0.1, 30) : 0
        let frame = scratch + "/frame.png"
        try run("ffmpeg", ["-v", "error", "-threads", "2", "-y", "-ss", String(format: "%.2f", seek), "-i", input,
                           "-map", "0:v:0", "-an",
                           "-vf", "\(toneMap)thumbnail=n=30,scale=w='min(iw,\(width))':h='min(ih,\(height))':force_original_aspect_ratio=decrease",
                           "-frames:v", "1", frame], timeout: 180)
        try renderImage(frame, width: width, height: height, to: output)
    }

    /// macOS icons: the largest image in the icon family (ImageMagick has no ICNS reader).
    func renderIcon(_ input: String, width: Int, height: Int, to output: String, scratch: String) throws {
        let icons = scratch + "/icns"
        try FileManager.default.createDirectory(atPath: icons, withIntermediateDirectories: true)
        try run("icns2png", ["-x", "-o", icons, input])
        // icns2png names them "<icon>_<width>x<height>x<depth>.png".
        func size(_ name: String) -> Int {
            Int(name.split(separator: "_").last?.split(separator: "x").first ?? "") ?? 0
        }
        let pngs = try FileManager.default.contentsOfDirectory(atPath: icons).filter { $0.hasSuffix(".png") }
        guard let largest = pngs.max(by: { size($0) < size($1) }) else { throw ToolError("no image in the icon") }
        try renderImage(icons + "/" + largest, width: width, height: height, to: output)
    }
}

/// Width and height of a WebP file, read from its header (VP8, VP8L or VP8X).
public func webpSize(_ data: Data) -> (width: Int, height: Int)? {
    let b = [UInt8](data.prefix(32))
    guard b.count >= 30, b[0...3] == [0x52, 0x49, 0x46, 0x46], b[8...11] == [0x57, 0x45, 0x42, 0x50] else { return nil }
    let chunk = String(decoding: b[12...15], as: UTF8.self)
    switch chunk {
    case "VP8 ":
        return ((Int(b[26]) | Int(b[27]) << 8) & 0x3FFF, (Int(b[28]) | Int(b[29]) << 8) & 0x3FFF)
    case "VP8L":
        let width = 1 + (Int(b[21]) | ((Int(b[22]) & 0x3F) << 8))
        let height = 1 + ((Int(b[22]) >> 6) | (Int(b[23]) << 2) | ((Int(b[24]) & 0x0F) << 10))
        return (width, height)
    case "VP8X":
        return (1 + (Int(b[24]) | Int(b[25]) << 8 | Int(b[26]) << 16), 1 + (Int(b[27]) | Int(b[28]) << 8 | Int(b[29]) << 16))
    default:
        return nil
    }
}
