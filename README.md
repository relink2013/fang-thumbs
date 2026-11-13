<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/icon-white.svg">
    <img src="docs/icon-black.svg" width="160" alt="FaNG Thumbs icon">
  </picture>
</p>

# FaNG Thumbs

Fast, consistent WebP previews for photos, camera RAW and video, in one container. It's built to replace Imaginary (and Nextcloud's scattered RAW, HEIC and video providers) with a single service that also understands the formats Apple devices and pro cameras produce.

> **Status: early, working.** FaNG Thumbs started as the thumbnail worker of FaNG, a native Apple client for self-hosted files. The service and the Nextcloud app work and are being tested on a real Nextcloud 35 server; expect changes.

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
- **Documents:** PDF and Illustrator (first page), PostScript/EPS

## How it works

1. **The `fang-thumbs` container** (libvips with libheif, librsvg, poppler and ImageMagick; FFmpeg 9; ExifTool) exposes a small HTTP API: "make a preview of this file at this size". It answers with WebP. It reads files straight from mounted folders where it can, or takes the file in the request body.
2. **A Nextcloud app** registers FaNG Thumbs as the preview provider for every image and video type. Nextcloud's own providers stay on as a fallback, so previews keep working if the service is down.
3. **An `occ` command** pre-generates previews for a whole library in parallel batches. Preview Generator keeps handling new files afterwards.

Nextcloud stores the service's WebP as the largest preview byte for byte, with no second compression, and makes the smaller sizes from it.

## Setup with Nextcloud

1. **Run the service** next to Nextcloud. See [docker/docker-compose.example.yml](docker/docker-compose.example.yml). Mount Nextcloud's data directory and any local external storage at the same paths the Nextcloud container uses, read-only, and list them in `FANG_THUMBS_ROOTS`. Then `docker compose build && docker compose up -d`.
2. **Install the app:** copy `nextcloud/fangthumbs` into Nextcloud's `custom_apps` (or `apps`) folder, then:

   ```bash
   occ app:enable fangthumbs
   occ config:app:set fangthumbs url --value=http://nextcloud-fang-thumbs:9000
   occ config:app:set fangthumbs key --value=<FANG_THUMBS_KEY> --sensitive
   occ config:system:set preview_format --value=webp
   occ fangthumbs:test
   ```

3. **Generate previews** for everything: `occ fangthumbs:generate` (or `--user`, `--path`). It skips files that already have one, so it can be stopped and restarted. Storing previews in Nextcloud is one file at a time per process; to go faster, run several side by side with `--shard 0/4`, `--shard 1/4`, … `--shard 3/4`.
4. Optional: remove `OC\Preview\Imaginary` and `OC\Preview\ImaginaryPDF` from `enabledPreviewProviders` and retire the Imaginary container. Leave Nextcloud's other providers enabled: they're the fallback.

## Service settings

| Variable | Default | Meaning |
| --- | --- | --- |
| `FANG_THUMBS_KEY` | (none) | Required key (`Authorization: Bearer …`); strongly recommended |
| `FANG_THUMBS_ROOTS` | (none) | Folders it may read by path, separated by `:`; without it, only uploaded files are rendered |
| `FANG_THUMBS_PATH_MAP` | (none) | `from=to;from=to` path prefixes to rewrite, when the service sees files at other paths |
| `FANG_THUMBS_WORKERS` | half the CPUs | Previews rendered at once |
| `FANG_THUMBS_QUALITY` | `80` | WebP quality |
| `FANG_THUMBS_MAX_UPLOAD_MB` | `2048` | Largest file accepted as an upload |
| `PUID` / `PGID` | `99` / `100` | User the service runs as |

## HTTP API

- `POST /preview?path=/abs/path&width=1024&height=1024[&mime=…]`, or `?name=file.ext` with the file as the body: `200 image/webp` with `Image-Width`, `Image-Height` and `X-Fang-Source` (`embedded`, `rendered`, `video`); `403` path not allowed, `404` no such file, `415` unsupported, `422` couldn't be rendered.
- `POST /warm` with `{"width":1024,"height":1024,"files":[{"path":"…"}]}`: renders the batch in parallel and keeps the results for an hour, until they're asked for with `/preview`.
- `GET /health`

## License

MIT
