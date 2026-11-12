# FaNG Thumbs

Fast, consistent WebP previews for photos, camera RAW and video, in one container. It's built to replace Imaginary (and Nextcloud's scattered RAW, HEIC and video providers) with a single service that also understands the formats Apple devices and pro cameras produce.

> **Status: in development.** FaNG Thumbs started as the thumbnail worker of FaNG, a native Apple client for self-hosted files. This repository is where it becomes a standalone service anyone can use. It isn't ready for use yet.

## Why

- **One place for all media previews.** Today a Nextcloud server needs Imaginary for common images, the Camera RAW Previews app for RAW files, ffmpeg's Movie provider for video and built-in providers for HEIC and TIFF. Each has its own quirks, output format and quality setting.
- **WebP everywhere.** Every preview comes out as WebP at one quality setting. A PNG preview of a PNG image is often 5–10 times larger than the same preview in WebP.
- **Apple and pro formats first:**
  - ProRAW and every major camera RAW: the camera's embedded preview is used first, so it's fast and looks like the camera's own rendering;
  - HEIC/HEIF;
  - ProRes and ProRes RAW, HEVC (including HDR clips, tone-mapped so they don't look washed out), MXF and AVCHD.
- **Parallel.** Many previews are rendered at once, sized to the machine's CPUs and memory, so pre-generating a large library takes hours instead of days.
- **Reads files in place**, read-only, with no copying through HTTP when the files are on the same machine.

## Formats

- **Images:** JPEG, PNG/APNG, GIF, WebP, HEIC/HEIF, AVIF, JPEG XL, JPEG 2000, TIFF, BMP, ICO/CUR/ICNS, TGA, PSD/PSB, EXR, HDR, DPX, SVG/SVGZ, PNM family, XCF, QOI, DDS, PCX, EPS
- **Camera RAW:** DNG (including Apple ProRAW), CR2, CR3, CRW, NEF, NRW, ARW, SRF, SR2, RAF, ORF, RW2, PEF, SRW, X3F, 3FR, ERF, KDC, MOS, MRW, DCR, IIQ, RWL, GPR, FFF
- **Video:** MOV/QT (ProRes, ProRes RAW, HEVC, H.264), MP4/M4V, MKV, WebM, AVI, WMV/ASF, FLV/F4V, MPEG, TS/M2TS/MTS, VOB, 3GP/3G2, OGV, MXF, DV

Planned: PDF (first page).

## How it will work

1. **The `fang-thumbs` container** (libvips with libheif and ImageMagick, FFmpeg, ExifTool) exposes a small HTTP API: "make a preview of this file at this size". It answers with WebP. It reads files straight from mounted folders where it can, or takes the file in the request body.
2. **A Nextcloud app** registers FaNG Thumbs as the preview provider for every image and video type. Nextcloud's own providers stay on as a fallback, so previews keep working if the service is down.
3. **An `occ` command** pre-generates previews for a whole library in parallel batches. Preview Generator keeps handling new files afterwards.

## License

MIT
