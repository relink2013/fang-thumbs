<?php

declare(strict_types=1);

namespace OCA\FangThumbs\Command;

use OCA\FangThumbs\Preview\Provider;
use OCA\FangThumbs\Service\Client;
use OCP\DB\QueryBuilder\IQueryBuilder;
use OCP\Files\File;
use OCP\Files\Folder;
use OCP\Files\IRootFolder;
use OCP\IAppConfig;
use OCP\IConfig;
use OCP\IDBConnection;
use OCP\IPreview;
use OCP\IUser;
use OCP\IUserManager;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

/**
 * Pre-generates previews for every image and video, in parallel: each batch is first rendered on the service
 * all at once (its workers busy), then Nextcloud stores each one (fetching the finished largest preview and
 * making the smaller sizes from it). Files that already have a largest preview are skipped, so a run that was
 * stopped picks up where it left off.
 */
class Generate extends Command {
	public function __construct(
		private Client $client,
		private IRootFolder $rootFolder,
		private IUserManager $userManager,
		private IPreview $preview,
		private IConfig $config,
		private IAppConfig $appConfig,
		private IDBConnection $db,
	) {
		parent::__construct();
	}

	protected function configure(): void {
		$this->setName('fangthumbs:generate')
			->setDescription('Generate previews for all images and videos, rendered in parallel by FaNG Thumbs')
			->addOption('user', 'u', InputOption::VALUE_REQUIRED | InputOption::VALUE_IS_ARRAY, 'Only these users (default: all)')
			->addOption('path', 'p', InputOption::VALUE_REQUIRED, 'Only this folder, as a user sees it, e.g. "/alice/files/Photos"')
			->addOption('batch', 'b', InputOption::VALUE_REQUIRED, 'Files per batch (default: 4 × the service\'s workers)');
	}

	protected function execute(InputInterface $input, OutputInterface $output): int {
		$health = $this->client->health();
		if ($health === null) {
			$output->writeln('<error>The FaNG Thumbs service does not answer; run occ fangthumbs:test</error>');
			return 1;
		}
		$batchSize = (int)($input->getOption('batch') ?: max(8, 4 * (int)($health['workers'] ?? 4)));
		$maxX = $this->config->getSystemValueInt('preview_max_x', 4096);
		$maxY = $this->config->getSystemValueInt('preview_max_y', 4096);
		$sizes = $this->sizes();
		$output->writeln(sprintf('Batches of %d, largest preview %d×%d, then %d smaller sizes', $batchSize, $maxX, $maxY, count($sizes)));

		$this->started = microtime(true);
		$path = $input->getOption('path');
		if (is_string($path) && $path !== '') {
			$node = $this->rootFolder->get($path);
			$this->walk($node, $output, $batchSize, $maxX, $maxY, $sizes);
		} else {
			$users = $input->getOption('user');
			$each = function (IUser $user) use ($output, $batchSize, $maxX, $maxY, $sizes): void {
				$output->writeln('<info>' . $user->getUID() . '</info>');
				$this->walk($this->rootFolder->getUserFolder($user->getUID()), $output, $batchSize, $maxX, $maxY, $sizes);
			};
			if ($users === []) {
				$this->userManager->callForSeenUsers($each);
			} else {
				foreach ($users as $uid) {
					$user = $this->userManager->get($uid);
					$user === null ? $output->writeln("<error>No user $uid</error>") : $each($user);
				}
			}
		}
		$this->flush($output, $maxX, $maxY, $sizes);
		$output->writeln(sprintf('<info>Done: %d made, %d already there, %d failed, in %s</info>',
			$this->made, $this->skipped, $this->failed, $this->elapsed()));
		return 0;
	}

	/** @var File[] */
	private array $batch = [];
	/** @var array<int, true> file ids seen this run (a file can be reached by several users) */
	private array $seen = [];
	private int $made = 0;
	private int $skipped = 0;
	private int $failed = 0;
	private float $started = 0;
	private int $batchSize = 64;

	private function walk(\OCP\Files\Node $node, OutputInterface $output, int $batchSize, int $maxX, int $maxY, array $sizes): void {
		$this->batchSize = $batchSize;
		if ($node instanceof File) {
			$this->consider($node, $output, $maxX, $maxY, $sizes);
			return;
		}
		if (!$node instanceof Folder) {
			return;
		}
		// Files shared with this user belong to their owner, who gets them in their own walk.
		if ($node->getStorage()->instanceOfStorage('\OCA\Files_Sharing\SharedStorage') && $node->getInternalPath() === '') {
			return;
		}
		if ($node->nodeExists('.nomedia') || $node->nodeExists('.noimage')) {
			return;
		}
		try {
			$children = $node->getDirectoryListing();
		} catch (\Throwable $e) {
			$output->writeln('<comment>Skipped a folder that can\'t be listed: ' . $e->getMessage() . '</comment>');
			return;
		}
		foreach ($children as $child) {
			$this->walk($child, $output, $batchSize, $maxX, $maxY, $sizes);
		}
	}

	private function consider(File $file, OutputInterface $output, int $maxX, int $maxY, array $sizes): void {
		$id = $file->getId();
		if ($id === null || isset($this->seen[$id]) || $file->getSize() <= 0
			|| !preg_match(Provider::MIME_PATTERN, $file->getMimeType())) {
			return;
		}
		$this->seen[$id] = true;
		$this->batch[] = $file;
		if (count($this->batch) >= $this->batchSize) {
			$this->flush($output, $maxX, $maxY, $sizes);
		}
	}

	private function flush(OutputInterface $output, int $maxX, int $maxY, array $sizes): void {
		if ($this->batch === []) {
			return;
		}
		$have = $this->haveLargest(array_map(fn (File $f) => $f->getId(), $this->batch));
		$todo = array_values(array_filter($this->batch, fn (File $f) => !isset($have[$f->getId()])));
		$this->skipped += count($this->batch) - count($todo);
		$this->batch = [];
		if ($todo === []) {
			return;
		}
		// All of them at once on the service; Nextcloud then fetches each finished one.
		$this->client->warm($todo, $maxX, $maxY);
		foreach ($todo as $file) {
			try {
				$this->preview->generatePreviews($file, $sizes);
				$this->made++;
			} catch (\Throwable $e) {
				$this->failed++;
				if ($output->isVerbose()) {
					$output->writeln("<comment>File {$file->getId()}: {$e->getMessage()}</comment>");
				}
			}
		}
		$output->writeln(sprintf('  %d made, %d already there, %d failed (%s, %.1f per second)',
			$this->made, $this->skipped, $this->failed, $this->elapsed(),
			$this->made / max(1, microtime(true) - $this->started)));
	}

	/**
	 * Which of these files already have a largest preview (Nextcloud's previews table; if its layout changes,
	 * nothing is skipped and existing previews are simply found by Nextcloud itself).
	 *
	 * @param int[] $ids
	 * @return array<int, true>
	 */
	private function haveLargest(array $ids): array {
		try {
			$query = $this->db->getQueryBuilder();
			$query->select('file_id')->from('previews')
				->where($query->expr()->in('file_id', $query->createNamedParameter($ids, IQueryBuilder::PARAM_INT_ARRAY)))
				->andWhere($query->expr()->eq('max', $query->createNamedParameter(true, IQueryBuilder::PARAM_BOOL)));
			$result = $query->executeQuery();
			$have = [];
			while ($row = $result->fetch()) {
				$have[(int)$row['file_id']] = true;
			}
			$result->closeCursor();
			return $have;
		} catch (\Throwable $e) {
			return [];
		}
	}

	/**
	 * The smaller sizes to make: Preview Generator's settings when they're set (so both make the same
	 * sizes), else its defaults.
	 */
	private function sizes(): array {
		$list = fn (string $key, string $default) => array_filter(array_map('intval',
			explode(' ', $this->appConfig->getValueString('previewgenerator', $key, $default))));
		$specs = [];
		foreach ($list('squareSizes', '32 256') as $size) {
			$specs[] = ['width' => $size, 'height' => $size, 'crop' => true];
		}
		foreach ($list('widthSizes', '256 384') as $size) {
			$specs[] = ['width' => $size, 'height' => -1, 'crop' => false];
		}
		foreach ($list('heightSizes', '256') as $size) {
			$specs[] = ['width' => -1, 'height' => $size, 'crop' => false];
		}
		return $specs;
	}

	private function elapsed(): string {
		$s = (int)(microtime(true) - $this->started);
		return sprintf('%d:%02d:%02d', intdiv($s, 3600), intdiv($s % 3600, 60), $s % 60);
	}
}
