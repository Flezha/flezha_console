import { test, expect, choose, withStepsRelay, expectAdvances } from './fixtures';

/**
 * A relay's durable state: its cells, their counters, and the point-in-time
 * read.
 *
 * `testnet_store_1` persists a cell per input, so it has real WAL and snapshot
 * sequences. Their values are not asserted — they move — only that they are
 * reported.
 */
test.describe('Relay durable state', () => {
  test.beforeEach(async ({ live }) => {
    await live('/namespaces/default/relays/testnet_store_1/state');
  });

  test('lists cells grouped by tasklet with their durability metrics', async ({ page }) => {
    const tasklets = page.locator('[data-testid^="tasklet-"]');
    await expect(tasklets.first()).toBeVisible();

    const rows = page.locator('[data-testid^="cell-"]:not([data-testid^="cell-lagging-"])');
    const count = await rows.count();
    expect(count).toBeGreaterThan(0);

    // Sequence numbers are reported, whatever they currently are.
    await expect(rows.first()).toContainText(/\d+/);
  });

  test('states the history retention of a flow relay, and no finished-instance one', async ({
    page,
  }) => {
    await expect(page.getByTestId('history-retention')).toContainText(/\d+ hours/);
    await expect(page.getByTestId('finished-retention')).toHaveCount(0);
  });

  test('a steps relay states both its history and its finished-instance retention', async ({
    page,
    live,
  }) => {
    await withStepsRelay(page, async (id) => {
      await live(`/namespaces/default/relays/${id}/state`);
      await expect(page.getByTestId('history-retention')).toContainText(/\d+ hours/);
      await expect(page.getByTestId('finished-retention')).toContainText(/\d+ hours/);
    });
  });

  test('the lag chart says the series is sampled by this UI', async ({ page }) => {
    await expect(page.getByTestId('lag-chart')).toBeVisible();

    // Each tick adds a sample to every cell's series.
    const series = page.locator('[data-testid^="spark-"]').first().locator('span');
    await expectAdvances(() => series.count(), 'the lag series');

    const provenance = page.getByTestId('chart-provenance');
    await expect(provenance).toContainText('Sampled by this UI');
    await expect(provenance).toContainText('never interpolated');
  });

  test('a point-in-time read states the sequence it resolved and the sizes', async ({ page }) => {
    await page.locator('[data-testid^="select-"]').first().click();

    const travel = page.getByTestId('time-travel');
    await expect(travel).toBeVisible();

    await choose(page, 'travel-kind', 'seq');
    await page.getByTestId('travel-value').fill('1');
    await page.getByTestId('travel-submit').click();

    // Either where the history stands at that sequence, or the controller's
    // own reason for refusing it — never a silent nothing.
    await expect(
      page.getByTestId('travel-result').or(page.getByTestId('travel-error')),
    ).toBeVisible();

    if ((await page.getByTestId('travel-result').count()) > 0) {
      await expect(page.getByTestId('travel-seq')).toHaveText(/\d+/);
      await expect(page.getByTestId('travel-snapshot-size')).toBeVisible();
      await expect(page.getByTestId('travel-change-log-size')).toBeVisible();
    }
  });

  test('a target that is neither a sequence nor a time is refused on the form', async ({
    page,
  }) => {
    await page.locator('[data-testid^="select-"]').first().click();

    await choose(page, 'travel-kind', 'time');
    await page.getByTestId('travel-value').fill('yesterday');
    await page.getByTestId('travel-submit').click();

    await expect(page.getByTestId('travel-error')).toContainText('ISO 8601');
    await expect(page.getByTestId('travel-result')).toHaveCount(0);
  });
});
