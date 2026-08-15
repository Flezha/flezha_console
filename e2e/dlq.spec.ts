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

  test('renders the empty queue', async ({ page }) => {
    await expect(page.getByTestId('dlq-empty')).toContainText('The dead-letter queue is empty');
  });

  test('filters by operative class', async ({ page }) => {
    await page.getByTestId('dlq-filter').fill('no_such_operative_class');

    await expect(page.getByTestId('dlq-empty')).toContainText(
      'No parked entries for that operative class',
    );
  });

  test('clearing the filter restores the unfiltered empty state', async ({ page }) => {
    await page.getByTestId('dlq-filter').fill('no_such_operative_class');
    await expect(page.getByTestId('dlq-empty')).toContainText('No parked entries for that');

    await page.getByTestId('dlq-filter').fill('');
    await expect(page.getByTestId('dlq-empty')).toContainText('The dead-letter queue is empty');
  });
});
