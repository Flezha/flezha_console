import {
  test,
  expect,
  sendToRelay,
  startRelay,
  stopRelay,
  uniqueId,
  visitLive,
  confirmEach,
  type Page,
} from './fixtures';

/**
 * The dead-letter queue screen, against entries each test parks itself.
 *
 * The dev runner's `poison_probe` factory fails on the input `poison` until it
 * is sent `antidote`; after its retries the controller parks the input. The
 * antidote is never sent, because it is process-wide on the runner and would
 * change every later run. Each test starts its own relay under a run-unique id,
 * filters the queue to that relay class, and drops every entry it parked and
 * stops the relay in `finally`.
 */
const TASKLET = 'poison_probe_tasklet';

/** Starts a poison probe relay, parks one entry in it, and runs `body`. */
async function withParked(
  page: Page,
  body: (relay: string, ref: string) => Promise<void>,
): Promise<void> {
  const relay = uniqueId('pw_dlq');
  await visitLive(page, '/namespaces/default');
  await startRelay(page, relay, { factory: 'poison_probe' });

  try {
    await visitLive(page, `/namespaces/default/relays/${relay}`);
    await sendToRelay(page, 'poison', { channel: 'input' });

    await visitLive(page, '/dlq');
    await page.getByTestId('dlq-filter').fill(relay);
    await expect(page.getByTestId(`dlq-group-count-${relay}-${TASKLET}`)).toHaveText('1 parked', {
      timeout: 20_000,
    });

    const group = page.getByTestId(`dlq-group-${relay}-${TASKLET}`);
    const ref = (await group
      .locator('[data-testid^="dlq-row-"]')
      .getAttribute('data-testid'))!.slice('dlq-row-'.length);
    await body(relay, ref);
  } finally {
    // Only this relay's group is ever touched: the queue is shared.
    await visitLive(page, '/dlq');
    await confirmEach(
      page,
      page.getByTestId(`dlq-group-${relay}-${TASKLET}`).locator('[data-testid^="dlq-drop-"]'),
      'dlq-confirm-submit',
    );
    await visitLive(page, '/namespaces/default');
    await stopRelay(page, relay);
  }
}

test.describe('Dead-letter queue', () => {
  test('a poisoned input is parked under its relay and tasklet, and counted', async ({ page }) => {
    await withParked(page, async (relay, ref) => {
      const row = page.getByTestId(`dlq-row-${ref}`);
      await expect(row).toContainText('input');
      await expect(row).toContainText('poison payload');
      await expect(page.getByTestId('dlq-stats')).toContainText(`${relay}/${TASKLET}`);
    });
  });

  test('the relay class filter narrows the queue and clearing it brings the entries back', async ({
    page,
  }) => {
    await withParked(page, async (relay) => {
      await page.getByTestId('dlq-filter').fill('no_such_relay_class');
      await expect(page.getByTestId('dlq-empty')).toContainText(
        'No parked entries for that relay class',
      );
      await expect(page.getByTestId(`dlq-group-${relay}-${TASKLET}`)).toHaveCount(0);

      await page.getByTestId('dlq-filter').fill('');
      await expect(page.getByTestId(`dlq-group-${relay}-${TASKLET}`)).toBeVisible();
      await expect(page.getByTestId('dlq-empty')).toHaveCount(0);
    });
  });

  test('inspecting an entry shows its payload, and the dialog closes', async ({ page }) => {
    await withParked(page, async (_relay, ref) => {
      await page.getByTestId(`dlq-inspect-${ref}`).click();
      await expect(page.getByTestId('dlq-inspect-modal')).toBeVisible();
      await expect(page.getByTestId('dlq-payload')).toContainText('poison');

      await page.getByTestId('dlq-inspect-close').click();
      await expect(page.getByTestId('dlq-inspect-modal')).toHaveCount(0);
    });
  });

  test('a replay is confirm-gated, and one that fails again is parked as the next generation', async ({
    page,
  }) => {
    await withParked(page, async (_relay, ref) => {
      await page.getByTestId(`dlq-replay-${ref}`).click();
      await expect(page.getByTestId('dlq-confirm-modal')).toContainText('Re-send');
      await page.getByTestId('dlq-confirm-cancel').click();
      await expect(page.getByTestId('dlq-confirm-modal')).toHaveCount(0);
      await expect(page.getByTestId('replay-pending')).toHaveCount(0);
      await expect(page.getByTestId(`dlq-row-${ref}`)).toBeVisible();

      await page.getByTestId(`dlq-replay-${ref}`).click();
      await page.getByTestId('dlq-confirm-submit').click();
      await expect(page.getByTestId('replay-reparked')).toContainText('generation 2', {
        timeout: 30_000,
      });
    });
  });

  test('a drop is confirm-gated, and confirming removes the entry for good', async ({ page }) => {
    await withParked(page, async (relay, ref) => {
      await page.getByTestId(`dlq-drop-${ref}`).click();
      await expect(page.getByTestId('dlq-confirm-modal')).toContainText('permanent');
      await page.getByTestId('dlq-confirm-cancel').click();
      await expect(page.getByTestId('dlq-confirm-modal')).toHaveCount(0);
      await expect(page.getByTestId(`dlq-row-${ref}`)).toBeVisible();
      await expect(page.getByTestId(`dlq-group-count-${relay}-${TASKLET}`)).toHaveText('1 parked');

      await page.getByTestId(`dlq-drop-${ref}`).click();
      await page.getByTestId('dlq-confirm-submit').click();
      await expect(page.getByTestId(`dlq-row-${ref}`)).toHaveCount(0);
      await expect(page.getByTestId('dlq-empty')).toContainText(
        'No parked entries for that relay class',
      );
    });
  });
});
