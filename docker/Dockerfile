# FaNG Thumbs: libvips (libheif, librsvg, poppler, ImageMagick), FFmpeg and ExifTool behind a small HTTP service.
# Build from the repository root: docker build -f docker/Dockerfile -t fang-thumbs .

FROM swift:6.2-bookworm AS build
WORKDIR /src
COPY service/Package.swift service/Package.resolved* ./
RUN swift package resolve
COPY service/Sources Sources
COPY service/Tests Tests
RUN swift build -c release --static-swift-stdlib --product fang-thumbs && cp .build/release/fang-thumbs /

# Debian testing: FFmpeg 9 (ProRes RAW decoding needs 8 or later) and a current libheif and libvips.
FROM debian:testing-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        tini libvips-tools libheif-plugin-libde265 libheif-plugin-dav1d libheif-plugin-aomdec \
        ffmpeg libimage-exiftool-perl icnsutils libstdc++6 ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /fang-thumbs /usr/local/bin/
COPY docker/entrypoint.sh /usr/local/bin/
RUN chmod 755 /usr/local/bin/entrypoint.sh \
    && ! (ldd /usr/local/bin/fang-thumbs | grep "not found") \
    && vips --vips-config | head -3 && ffmpeg -hide_banner -decoders | grep -E "prores"
ENV FANG_THUMBS_CACHE=/tmp/fang-thumbs FANG_THUMBS_PORT=9000 PUID=99 PGID=100
EXPOSE 9000
HEALTHCHECK --interval=60s --timeout=5s CMD curl -fsS http://127.0.0.1:${FANG_THUMBS_PORT}/health >/dev/null || exit 1
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
