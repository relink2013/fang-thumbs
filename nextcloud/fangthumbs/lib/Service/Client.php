<?php

declare(strict_types=1);

namespace OCA\FangThumbs\Service;

use OCA\FangThumbs\AppInfo\Application;
use OCA\FangThumbs\Preview\WebpImage;
use OCP\Files\File;
use OCP\Http\Client\IClientService;
use OCP\IAppConfig;
use Psr\Log\LoggerInterface;

/**
 * Talks to the FaNG Thumbs service.
 *
 * A file on local storage is sent by path (the service reads it directly, from the same paths the Nextcloud
 * container sees). If the service can't see that path, or the file isn't on local storage, the file itself is
 * sent, up to max_upload_mb; anything larger is left to Nextcloud's own providers.
 */
class Client {
	public function __construct(
		private IClientService $clients,
		private IAppConfig $appConfig,
		private LoggerInterface $logger,
	) {
	}

	public function url(): string {
		return rtrim($this->appConfig->getValueString(Application::APP_ID, 'url', ''), '/');
	}

	public function isConfigured(): bool {
		return $this->url() !== '';
	}

	private function headers(): array {
		$key = $this->appConfig->getValueString(Application::APP_ID, 'key', '', lazy: true);
		return $key === '' ? [] : ['Authorization' => 'Bearer ' . $key];
	}

	/** The path the service should read, or null when the file isn't on local storage. */
	public function localPath(File $file): ?string {
		try {
			$storage = $file->getStorage();
			if (!$storage->isLocal()) {
				return null;
			}
			$path = $storage->getLocalFile($file->getInternalPath());
			return is_string($path) && $path !== '' ? $path : null;
		} catch (\Throwable $e) {
			return null;
		}
	}

	/** The largest preview, fitting in width × height, or null to let Nextcloud's own providers try. */
	public function preview(File $file, int $width, int $height): ?WebpImage {
		if (!$this->isConfigured()) {
			return null;
		}
		$query = ['width' => $width, 'height' => $height, 'mime' => $file->getMimeType()];
		$path = $this->localPath($file);
		if ($path !== null) {
			[$status, $image] = $this->request($query + ['path' => $path], null, $file);
			// 403/404: the service doesn't see this path; send the file instead.
			if ($status !== 403 && $status !== 404) {
				return $image;
			}
		}
		$limit = $this->appConfig->getValueInt(Application::APP_ID, 'max_upload_mb', 512) * 1024 * 1024;
		if ($file->getSize() > $limit) {
			return null;
		}
		$stream = $file->fopen('r');
		if ($stream === false) {
			return null;
		}
		[, $image] = $this->request($query + ['name' => $file->getName()], $stream, $file);
		return $image;
	}

	/**
	 * @param resource|null $body
	 * @return array{0: int, 1: ?WebpImage}
	 */
	private function request(array $query, $body, ?File $file): array {
		try {
			$options = [
				'query' => $query,
				'headers' => $this->headers(),
				'stream' => true,
				'timeout' => 300,
				'connect_timeout' => 3,
				'nextcloud' => ['allow_local_address' => true],
			];
			if ($body !== null) {
				$options['body'] = $body;
			}
			$response = $this->clients->newClient()->post($this->url() . '/preview', $options);
			$width = (int)$response->getHeader('Image-Width');
			$height = (int)$response->getHeader('Image-Height');
			$stream = $response->getBody();
			if (!is_resource($stream)) {
				$data = (string)$stream;
				$stream = fopen('php://temp', 'w+');
				fwrite($stream, $data);
				rewind($stream);
			}
			$image = new WebpImage($stream, $width, $height);
			return [200, $image->valid() ? $image : null];
		} catch (\Throwable $e) {
			$status = (int)$e->getCode();
			// 415: a type the service doesn't render; 422: it couldn't. Neither is worth more than a debug line.
			$level = in_array($status, [403, 404, 415, 422], true) ? 'debug' : 'info';
			$this->logger->$level('FaNG Thumbs: no preview for file {id} ({status}): {message}', [
				'id' => $file?->getId() ?? ($query['name'] ?? '?'), 'status' => $status, 'message' => $e->getMessage(), 'app' => Application::APP_ID,
			]);
			return [$status, null];
		}
	}

	/** The preview of a file outside Nextcloud's storage (the app's own samples), sent as an upload. */
	public function previewOfData(string $path): ?WebpImage {
		$stream = fopen($path, 'r');
		if ($stream === false) {
			return null;
		}
		[, $image] = $this->request(['width' => 1024, 'height' => 1024, 'name' => basename($path)], $stream, null);
		return $image;
	}

	/** Service health, or null when it can't be reached. */
	public function health(): ?array {
		try {
			$response = $this->clients->newClient()->get($this->url() . '/health', [
				'headers' => $this->headers(), 'timeout' => 10, 'nextcloud' => ['allow_local_address' => true],
			]);
			$health = json_decode((string)$response->getBody(), true);
			return is_array($health) ? $health : null;
		} catch (\Throwable $e) {
			return null;
		}
	}

	/**
	 * Renders a batch in parallel on the service, which keeps the results until they're fetched as previews.
	 *
	 * @param File[] $files
	 * @return int how many were rendered
	 */
	public function warm(array $files, int $width, int $height): int {
		$list = [];
		foreach ($files as $file) {
			$path = $this->localPath($file);
			if ($path !== null) {
				$list[] = ['path' => $path, 'mime' => $file->getMimeType()];
			}
		}
		if ($list === []) {
			return 0;
		}
		try {
			$response = $this->clients->newClient()->post($this->url() . '/warm', [
				'json' => ['width' => $width, 'height' => $height, 'files' => $list],
				'headers' => $this->headers(),
				'timeout' => 3600,
				'connect_timeout' => 3,
				'nextcloud' => ['allow_local_address' => true],
			]);
			$results = json_decode((string)$response->getBody(), true)['results'] ?? [];
			return count(array_filter($results, fn ($r) => $r['ok'] ?? false));
		} catch (\Throwable $e) {
			$this->logger->info('FaNG Thumbs: warm-up failed: ' . $e->getMessage(), ['app' => Application::APP_ID]);
			return 0;
		}
	}
}
