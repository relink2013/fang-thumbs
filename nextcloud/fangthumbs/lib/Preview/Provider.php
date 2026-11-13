<?php

declare(strict_types=1);

namespace OCA\FangThumbs\Preview;

use OCA\FangThumbs\Service\Client;
use OCP\Files\File;
use OCP\Files\FileInfo;
use OCP\IImage;
use OCP\Preview\IProviderV2;

/**
 * Asks the FaNG Thumbs service for the largest preview of a file. Returning null hands the file to the next
 * provider (Nextcloud's own), so an unreachable service or an unsupported file never means no preview.
 */
class Provider implements IProviderV2 {
	/** Every MIME type the service may render; files of other types never reach it. */
	public const MIME_PATTERN = '/^(image\/(bmp|gif|heic|heif|jp2|jpeg|png|svg\+xml|tga|tiff|webp|x-dcraw|x-icon|avif|jxl|x-exr|x-icns|vnd\.radiance|x-portable-anymap|vnd\.adobe\.photoshop)|video\/.+|application\/(pdf|illustrator|postscript|x-photoshop|mxf))$/i';

	public function __construct(
		private Client $client,
	) {
	}

	public function getMimeType(): string {
		return self::MIME_PATTERN;
	}

	public function isAvailable(FileInfo $file): bool {
		return $this->client->isConfigured() && $file->getSize() > 0;
	}

	public function getThumbnail(File $file, int $maxX, int $maxY): ?IImage {
		return $this->client->preview($file, $maxX, $maxY);
	}
}
