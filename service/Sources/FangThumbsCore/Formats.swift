/// What a file is, for choosing how to render it.
public enum Kind: String, Sendable, Codable {
    /// Still images, rendered with libvips (libheif, librsvg, ImageMagick behind it).
    case image
    /// Camera RAW: the preview the camera (or Lightroom, Photoshop) embedded, else a render.
    case raw
    /// Video: a representative frame, HDR tone-mapped.
    case video
    /// PDF and Illustrator: the first page.
    case document
}

public enum Formats {
    public static let image: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif", "png", "apng", "gif", "webp", "heic", "heif", "hif", "avif", "tif", "tiff",
        "bmp", "dib", "ico", "cur", "icns", "tga", "psd", "psb", "jxl", "jp2", "j2k", "jpf", "jpx", "exr", "hdr",
        "dpx", "svg", "svgz", "ppm", "pgm", "pbm", "pnm", "pfm", "xcf", "qoi", "dds", "pcx", "eps",
    ]
    public static let raw: Set<String> = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2", "pef", "srw", "x3f",
        "3fr", "erf", "kdc", "mos", "mrw", "dcr", "iiq", "rwl", "gpr", "fff",
    ]
    public static let video: Set<String> = [
        "mp4", "m4v", "mov", "qt", "mkv", "webm", "avi", "wmv", "asf", "flv", "f4v", "mpg", "mpeg", "m2v", "mpe",
        "ts", "m2ts", "mts", "vob", "3gp", "3g2", "ogv", "mxf", "dv", "hevc", "h264", "y4m", "gifv",
    ]
    public static let document: Set<String> = ["pdf", "ai"]

    /// The kind of a file, from its extension, else from its MIME type (for files without a usable extension).
    public static func kind(extension ext: String, mimeType: String?) -> Kind? {
        let ext = ext.lowercased()
        if raw.contains(ext) { return .raw }
        if video.contains(ext) { return .video }
        if document.contains(ext) { return .document }
        if image.contains(ext) { return .image }
        guard let mime = mimeType?.lowercased() else { return nil }
        if mime == "image/x-dcraw" || mime.hasPrefix("image/x-") && mime.contains("raw") { return .raw }
        if mime.hasPrefix("video/") { return .video }
        if mime == "application/pdf" || mime == "application/illustrator" { return .document }
        if mime.hasPrefix("image/") { return .image }
        return nil
    }

    /// A file extension to use for a file of this kind when the name has none (tools pick decoders by content anyway).
    public static func fallbackExtension(for kind: Kind) -> String {
        switch kind {
        case .image: "img"
        case .raw: "dng"
        case .video: "mov"
        case .document: "pdf"
        }
    }
}
