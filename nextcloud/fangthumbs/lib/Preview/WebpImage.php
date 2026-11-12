<?php

declare(strict_types=1);

namespace OCA\FangThumbs\Preview;

use OCP\IImage;
use OCP\IStreamImage;

/**
 * A finished WebP from the service. As a stream image, Nextcloud stores it byte for byte as the largest
 * preview, without decoding and compressing it a second time; the smaller sizes are made from that stored
 * file. Nothing else is ever asked of it.
 */
class WebpImage implements IStreamImage {
	/** @param resource $stream */
	public function __construct(
		private $stream,
		private int $width,
		private int $height,
	) {
	}

	public function valid(): bool {
		return is_resource($this->stream) && $this->width > 0 && $this->height > 0;
	}

	public function mimeType(): ?string {
		return 'image/webp';
	}

	public function dataMimeType(): ?string {
		return 'image/webp';
	}

	public function width(): int {
		return $this->width;
	}

	public function height(): int {
		return $this->height;
	}

	public function resource() {
		return $this->stream;
	}

	public function data(): ?string {
		if (!is_resource($this->stream)) {
			return null;
		}
		rewind($this->stream);
		$data = stream_get_contents($this->stream);
		rewind($this->stream);
		return $data === false ? null : $data;
	}

	public function widthTopLeft(): int {
		return $this->width;
	}

	public function heightTopLeft(): int {
		return $this->height;
	}

	public function getOrientation(): int {
		return 1;
	}

	public function fixOrientation(): bool {
		return true;
	}

	public function show(?string $mimeType = null): bool {
		throw new \BadMethodCallException('Not implemented');
	}

	public function save(?string $filePath = null, ?string $mimeType = null): bool {
		throw new \BadMethodCallException('Not implemented');
	}

	public function resize(int $maxSize): bool {
		throw new \BadMethodCallException('Not implemented');
	}

	public function preciseResize(int $width, int $height): bool {
		throw new \BadMethodCallException('Not implemented');
	}

	public function centerCrop(int $size = 0): bool {
		throw new \BadMethodCallException('Not implemented');
	}

	public function crop(int $x, int $y, int $w, int $h): bool {
		throw new \BadMethodCallException('Not implemented');
	}

	public function fitIn(int $maxWidth, int $maxHeight): bool {
		throw new \BadMethodCallException('Not implemented');
	}

	public function scaleDownToFit(int $maxWidth, int $maxHeight): bool {
		throw new \BadMethodCallException('Not implemented');
	}

	public function copy(): IImage {
		throw new \BadMethodCallException('Not implemented');
	}

	public function cropCopy(int $x, int $y, int $w, int $h): IImage {
		throw new \BadMethodCallException('Not implemented');
	}

	public function preciseResizeCopy(int $width, int $height): IImage {
		throw new \BadMethodCallException('Not implemented');
	}

	public function resizeCopy(int $maxSize): IImage {
		throw new \BadMethodCallException('Not implemented');
	}

	public function loadFromData(string $str): \GdImage|false {
		throw new \BadMethodCallException('Not implemented');
	}

	public function readExif(string $data): void {
	}
}
