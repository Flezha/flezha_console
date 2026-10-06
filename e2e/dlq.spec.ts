import { test, expect } from './fixtures';

/**
 * The dead-letter queue screen.
 *
 * A healthy dev stack keeps the queue empty, so only the empty states are
 * assertable here — and they are asserted unconditionally. Everything that
 * needs parked entries (table shape, inspect modal, confirm-gated replay and
 * drop, the replay outcome after the grace period) lives in
 * `test/flezha_ui_web/live/dlq_live_test.exs`, where entries can be produced on
 * demand instead of waited for.
 */
test.describe('Dead-letter queue', () => {
  test.beforeEach(async ({ live }) => {
    await live('/dlq');
  });

  test('renders the queue, grouped by tasklet when it holds anything', async ({ page }) => {
    // The dev controller's `app_data` carries parked entries from earlier bench
    // campaigns, so an empty queue is one valid state of two — asserting a
    // total here would be asserting somebody else's leftovers.
    const empty = page.getByTestId('dlq-empty');

    if (await empty.count()) {
      await expect(empty).toContainText('The dead-letter queue is empty');
      return;
    }

    const groups = page.locator(
      '[data-testid^="dlq-group-"]:not([data-testid^="dlq-group-count-"])',
    );
    await expect(groups.first()).toBeVisible();
    await expect(page.locator('[data-testid^="dlq-group-count-"]').first()).toContainText(
      /\d+ parked/,
    );

    // Every entry sits inside a group rather than in one flat table.
    expect(await page.locator('[data-testid^="dlq-row-"]').count()).toBeGreaterThan(0);
  });

  test('filters by relay class', async ({ page }) => {
    await page.getByTestId('dlq-filter').fill('no_such_relay_class');

    await expect(page.getByTestId('dlq-empty')).toContainText(
      'No parked entries for that relay class',
    );
  });

  test('clearing the filter restores the unfiltered view', async ({ page }) => {
    await page.getByTestId('dlq-filter').fill('no_such_relay_class');
    await expect(page.getByTestId('dlq-empty')).toContainText('No parked entries for that');

    await page.getByTestId('dlq-filter').fill('');

    // Back to whatever the queue actually holds — grouped entries, or the
    // unfiltered empty state. Polled rather than asserted on one locator,
    // because which of the two exists depends on the controller's leftovers.
    await expect
      .poll(
        async () => {
          const groups = await page.locator('[data-testid^="dlq-group-"]').count();
          if (groups > 0) return 'entries';

          // Mid-render the empty state may not be attached at all, which is
          // neither of the two settled states — never an exception.
          const empty = await page
            .getByTestId('dlq-empty')
            .textContent({ timeout: 1_000 })
            .catch(() => null);

          if (empty === null) return 'rendering';

          return empty.includes('The dead-letter queue is empty') ? 'empty' : 'filtered';
        },
        { timeout: 15_000 },
      )
      .toMatch(/^(entries|empty)$/);
  });
});
