<?php

declare(strict_types=1);

namespace OCA\FangThumbs\AppInfo;

use OCA\FangThumbs\Preview\Provider;
use OCP\AppFramework\App;
use OCP\AppFramework\Bootstrap\IBootContext;
use OCP\AppFramework\Bootstrap\IBootstrap;
use OCP\AppFramework\Bootstrap\IRegistrationContext;

class Application extends App implements IBootstrap {
	public const APP_ID = 'fangthumbs';

	public function __construct() {
		parent::__construct(self::APP_ID);
	}

	public function register(IRegistrationContext $context): void {
		// Nextcloud asks providers with longer MIME patterns first; this one is longer than every built-in
		// pattern for these types, so FaNG Thumbs goes first and the built-in providers are the fallback.
		$context->registerPreviewProvider(Provider::class, Provider::MIME_PATTERN);
	}

	public function boot(IBootContext $context): void {
	}
}
