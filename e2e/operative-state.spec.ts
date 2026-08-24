import { test, expect, choose } from './fixtures';

/**
 * An operative's durable state: its entities, their counters, and the
 * point-in-time read.
 *
 * `testnet_store_1` persists an entity per input, so it has real WAL and
 * snapshot sequences. Their values are not asserted — they move — only that
 * they are reported.
 */
test.describe('Operative durable state', () => {
  test.beforeEach(async ({ live }) => {
    await live('/namespaces/default/operatives/testnet_store_1/state');
  });

  test('lists entities grouped by procedure with their durability metrics', async ({ page }) => {
    const procedures = page.locator('[data-testid^="procedure-"]');
    await expect(procedures.first()).toBeVisible();

    const rows = page.locator('[data-testid^="entity-"]:not([data-testid^="entity-lagging-"])');
    const count = await rows.count();
    expect(count).toBeGreaterThan(0);

    // Sequence numbers are reported, whatever they currently are.
    await expect(rows.first()).toContainText(/\d+/);
  });

  test('states the retention window and names flz for the destructive verbs', async ({ page }) => {
    await expect(page.getByTestId('state-retention')).toContainText(/hours|not reported/);

    const verbs = page.getByTestId('state-verbs');
    await expect(verbs).toContainText('flz state');
    // The screen reads; it does not offer a delete or a rotate.
    await expect(page.locator('[phx-click="delete_state"]')).toHaveCount(0);
    await expect(page.locator('[phx-click="rotate_state"]')).toHaveCount(0);
  });

  test('the lag chart says the series is sampled by this UI', async ({ page }) => {
    await expect(page.getByTestId('lag-chart')).toBeVisible();

    const provenance = page.getByTestId('chart-provenance');
    await expect(provenance).toContainText('Sampled by this UI');
    await expect(provenance).toContainText('never interpolated');
  });

  test('a point-in-time read states the target it resolved', async ({ page }) => {
    await page.locator('[data-testid^="select-"]').first().click();

    const travel = page.getByTestId('time-travel');
    await expect(travel).toBeVisible();

    await choose(page, 'travel-kind', 'seq');
    await page.getByTestId('travel-value').fill('1');
    await page.getByTestId('travel-submit').click();

    // Either the state at that sequence, or the controller's own reason for
    // refusing it — never a silent nothing.
    await expect(
      page.getByTestId('travel-result').or(page.getByTestId('travel-error')),
    ).toBeVisible();
  });
});
