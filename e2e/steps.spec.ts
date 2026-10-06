import { test, expect, openSection, startRelay, stopRelay, withStepsRelay } from './fixtures';

/**
 * The steps panel, task journal and input log, against a durable steps relay
 * each test starts for itself, and a finished relay made by stopping one.
 *
 * Whether a steps relay suspends, or how many iterations its journal holds,
 * depends on inputs a browser cannot send yet, so those states are asserted in
 * ExUnit against the fake controller rather than read off the live stack.
 */
test.describe('Steps relays', () => {
  test('a durable steps relay shows its steps panel', async ({ page, live }) => {
    await withStepsRelay(page, async (id) => {
      await live(`/namespaces/default/relays/${id}`);

    const panel = page.getByTestId('steps-panel');
    await expect(panel).toBeVisible();
    await expect(page.getByTestId('steps-durable')).toHaveText('yes');
    await expect(panel).toContainText('Effectively once');
    await expect(panel).toContainText('Arrived via hotswap');
    await expect(page.getByTestId('relay-run')).toHaveText('steps');

      // It initialised, so no init error is shown.
      await expect(page.getByTestId('steps-init-error')).toHaveCount(0);
    });
  });

  test('the task journal states its committed iterations and leaf tasklets', async ({
    page,
    live,
  }) => {
    await withStepsRelay(page, async (id) => {
      await live(`/namespaces/default/relays/${id}`);
      await openSection(page, 'journal');

      await expect(page.getByTestId('task-journal-panel')).toBeVisible();
      await expect(page.getByTestId('task-journal-committed')).toContainText(
        'committed iterations',
      );
      await expect(page.getByTestId('task-journal-leaves')).toContainText('leaf tasklets');
    });
  });

  test('the input log reports its depth and offsets', async ({ page, live }) => {
    await withStepsRelay(page, async (id) => {
      await live(`/namespaces/default/relays/${id}`);
      await openSection(page, 'input-log');

      await expect(page.getByTestId('input-log-panel')).toBeVisible();
      await expect(page.getByTestId('input-log-undelivered')).toHaveText(/^\s*\d+\s*$/);
      // An empty log is said in words, never as an offset of -1.
      await expect(page.getByTestId('input-log-last-offset')).toHaveText(
        /^\s*(\d+|no records)\s*$/,
      );
    });
  });

  test('a flow relay gets no steps, task journal or input log panel', async ({ page, live }) => {
    await live('/namespaces/default/relays/testnet_store_1');

    await expect(page.getByTestId('steps-panel')).toHaveCount(0);
    await expect(page.getByTestId('task-journal-panel')).toHaveCount(0);
    await expect(page.getByTestId('input-log-panel')).toHaveCount(0);
  });

  test('a stopped steps relay is listed as finished, with its completion record', async ({
    page,
    live,
  }) => {
    const id = `pw_fin_${Date.now().toString(36)}`;

    await live('/namespaces/default');
    await startRelay(page, id, { run: 'steps' });
    // A steps relay stops cooperatively and completes as cancelled.
    await stopRelay(page, id);

    await openSection(page, 'finished-relays');
    const row = page.getByTestId(`finished-row-${id}`);
    await expect
      .poll(
        async () => {
          await page.getByTestId('reload-finished').click();
          return row.count();
        },
        // Each read costs the controller an overwatch per live relay, so the
        // reload is not pressed faster than one read completes.
        { timeout: 30_000, intervals: [3_000] },
      )
      .toBe(1);
    await expect(row).toContainText('cancelled');

    await row.getByRole('link').click();
    await expect(page).toHaveURL(new RegExp(`/relays/${id}$`));

    const record = page.getByTestId('completion-record');
    await expect(record).toBeVisible();
    await expect(record).toContainText('cancelled');

    // Actions that need a live relay are absent rather than failing.
    await expect(page.getByTestId('task-journal-panel')).toHaveCount(0);
    await expect(page.getByTestId('stop-relay-btn')).toHaveCount(0);
  });
});
