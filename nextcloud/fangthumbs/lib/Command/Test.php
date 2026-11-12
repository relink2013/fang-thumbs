<?php

declare(strict_types=1);

namespace OCA\FangThumbs\Command;

use OCA\FangThumbs\Preview\Provider;
use OCA\FangThumbs\Service\Client;
use OCP\Files\File;
use OCP\Files\IRootFolder;
use OCP\Files\Node;
use OCP\IUserManager;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

/**
 * Checks that the service answers and renders. Exit code 0 only when every check passes, so it doubles as a
 * compatibility check after Nextcloud upgrades.
 */
class Test extends Command {
	public function __construct(
		private Client $client,
		private IRootFolder $rootFolder,
		private IUserManager $userManager,
	) {
		parent::__construct();
	}

	protected function configure(): void {
		$this->setName('fangthumbs:test')
			->setDescription('Check that the FaNG Thumbs service answers and renders previews')
			->addOption('user', 'u', InputOption::VALUE_REQUIRED, 'Also render a few of this user\'s own files by path');
	}

	protected function execute(InputInterface $input, OutputInterface $output): int {
		if (!$this->client->isConfigured()) {
			$output->writeln('<error>Not configured: occ config:app:set fangthumbs url --value=http://nextcloud-fang-thumbs:9000</error>');
			return 1;
		}
		$health = $this->client->health();
		if ($health === null) {
			$output->writeln('<error>The service at ' . $this->client->url() . ' does not answer (or the key is wrong)</error>');
			return 1;
		}
		$output->writeln(sprintf('Service: %d workers, WebP quality %d, HDR tone-mapping %s, reads files by path: %s',
			$health['workers'] ?? 0, $health['quality'] ?? 0, ($health['toneMapping'] ?? false) ? 'yes' : 'no',
			($health['pathAccess'] ?? false) ? 'yes' : 'no'));
		if (($health['missingTools'] ?? []) !== []) {
			$output->writeln('<comment>Missing tools: ' . implode(', ', $health['missingTools']) . '</comment>');
		}

		$failed = 0;
		// Sample files shipped with the app, sent as uploads (so they test rendering, not paths).
		$fixtures = __DIR__ . '/../../tests/fixtures';
		foreach (glob($fixtures . '/sample.*') ?: [] as $sample) {
			$failed += $this->check($output, basename($sample), fn () => $this->client->previewOfData($sample)) ? 0 : 1;
		}

		$uid = $input->getOption('user');
		if (is_string($uid) && $uid !== '') {
			if ($this->userManager->get($uid) === null) {
				$output->writeln("<error>No user $uid</error>");
				return 1;
			}
			$found = [];
			$this->find($this->rootFolder->getUserFolder($uid), $found, 3);
			foreach ($found as $mime => $file) {
				$failed += $this->check($output, "$mime (file {$file->getId()})",
					fn () => $this->client->preview($file, 1024, 1024)) ? 0 : 1;
			}
		}

		$output->writeln($failed === 0 ? '<info>All checks passed</info>' : "<error>$failed check(s) failed</error>");
		return $failed === 0 ? 0 : 1;
	}

	private function check(OutputInterface $output, string $label, callable $render): bool {
		$started = microtime(true);
		$image = $render();
		$ms = (int)((microtime(true) - $started) * 1000);
		$ok = $image !== null && $image->valid() && str_starts_with((string)$image->data(), 'RIFF');
		$output->writeln(sprintf('  %s %-36s %s', $ok ? '✓' : '✗', $label,
			$ok ? "{$image->width()}×{$image->height()} WebP in $ms ms" : 'no preview'));
		return $ok;
	}

	/** One file per MIME type the provider handles, from the first folders of the user's files. */
	private function find(Node $folder, array &$found, int $depth): void {
		if ($depth < 0 || count($found) >= 8) {
			return;
		}
		try {
			$nodes = $folder->getDirectoryListing();
		} catch (\Throwable $e) {
			return;
		}
		foreach ($nodes as $node) {
			if ($node instanceof File) {
				$mime = $node->getMimeType();
				if (!isset($found[$mime]) && preg_match(Provider::MIME_PATTERN, $mime) && $node->getSize() > 0) {
					$found[$mime] = $node;
				}
			}
		}
		foreach ($nodes as $node) {
			if (!$node instanceof File) {
				$this->find($node, $found, $depth - 1);
			}
		}
	}
}
