import { test, expect } from './fixtures';

/**
 * The workflow profile, journal and inbox, against the seeded instances.
 *
 * `testnet_chat` is a durable `chat_loop_workflow` that parks at its first
 * iteration boundary; `testnet_echo` runs once and completes, so it is read
 * back from its retained completion record rather than from the registry.
 */
test.describe('Workflow instances', () => {
  test('a durable workflow shows its profile', async ({ page, live }) => {
    await live('/namespaces/default/operatives/testnet_chat');

    const panel = page.getByTestId('workflow-panel');
    await expect(panel).toBeVisible();
    await expect(page.getByTestId('workflow-durable')).toHaveText('yes');
    await expect(panel).toContainText('Effectively once');
    await expect(panel).toContainText('Arrived via hotswap');

    // It initialised, so no init error is shown.
    await expect(page.getByTestId('workflow-init-error')).toHaveCount(0);
  });

  test('a suspended instance is marked suspended on its detail screen', async ({ page, live }) => {
    await live('/namespaces/default/operatives/testnet_chat');

    await expect(page.getByTestId('operative-suspended')).toBeVisible();
    await expect(page.getByTestId('operative-health')).toContainText('suspended');
  });

  test('the journal lists its entries, and a parked one states its wake deadline', async ({
    page,
    live,
  }) => {
    await live('/namespaces/default/operatives/testnet_chat');

    await expect(page.getByTestId('journal-panel')).toBeVisible();
    await expect(page.getByTestId('journal-panel')).toContainText('committed iterations');

    // The instance is parked, which is the entry the panel has to explain.
    const parked = page.locator('[data-testid^="journal-parked-"]');
    await expect(parked.first()).toContainText(/wakes at/);
  });

  test('the inbox reports its depth and offsets', async ({ page, live }) => {
    await live('/namespaces/default/operatives/testnet_chat');

    await expect(page.getByTestId('inbox-panel')).toBeVisible();
    await expect(page.getByTestId('inbox-undelivered')).toHaveText(/^\s*\d+\s*$/);
    await expect(page.getByTestId('inbox-last-offset')).toHaveText(/^\s*\d+\s*$/);
  });

  test('a stream operative gets no workflow, journal or inbox panel', async ({ page, live }) => {
    await live('/namespaces/default/operatives/testnet_store_1');

    await expect(page.getByTestId('workflow-panel')).toHaveCount(0);
    await expect(page.getByTestId('journal-panel')).toHaveCount(0);
    await expect(page.getByTestId('inbox-panel')).toHaveCount(0);
  });

  test('a finished instance is listed and its completion record is shown', async ({
    page,
    live,
  }) => {
    await live('/namespaces/default');

    const finished = page.getByTestId('finished-instances');
    await expect(finished).toBeVisible();

    const row = page.getByTestId('finished-row-testnet_echo');
    await expect(row).toBeVisible();

    await row.getByRole('link').click();
    await expect(page).toHaveURL(/\/operatives\/testnet_echo$/);

    const record = page.getByTestId('completion-record');
    await expect(record).toBeVisible();
    await expect(record).toContainText('Finished');

    // Actions that need a live operative are absent rather than failing.
    await expect(page.getByTestId('journal-panel')).toHaveCount(0);
  });

  test('a suspended instance can be found through the index filter', async ({ page, live }) => {
    await live('/operatives');
    await page.getByTestId('filter-health').selectOption('suspended');

    await expect(page.getByTestId('operative-index-row-testnet_chat')).toBeVisible();
    await expect(page.getByTestId('operative-index-row-testnet_store_1')).toHaveCount(0);
  });
});
