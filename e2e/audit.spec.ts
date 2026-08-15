import { test, expect } from './fixtures';

/**
 * The audit log screen.
 *
 * Every assertion here is unconditional. `docker-compose.dev.yml` defaults
 * `FLEZHA_AUDIT_ENABLED` to `true`, so an unset flag is a broken stack, not a
 * reason to skip — the screen's disabled state is covered in
 * `test/flezha_ui_web/live/audit_live_test.exs`, where it can be produced on
 * demand.
 */
test.describe('Audit log', () => {
  test.beforeEach(async ({ live }) => {
    await live('/audit');
  });

  test('renders the statistics panel', async ({ page }) => {
    await expect(
      page.getByTestId('audit-disabled'),
      'audit must be enabled on the controller — check FLEZHA_AUDIT_ENABLED',
    ).toHaveCount(0);

    await expect(page.getByTestId('audit-stats')).toBeVisible();
  });

  test('reads records and shows them', async ({ page }) => {
    await page.getByTestId('audit-read-btn').click();

    // Reading the audit log is itself audited, so there is always at least
    // this UI's own activity to find.
    await expect(page.getByTestId('audit-records')).toContainText('"source":"ui"');
  });

  test('reports when a filter matches nothing', async ({ page }) => {
    await page.getByTestId('audit-filter-source').fill('no_such_source');
    await page.getByTestId('audit-read-btn').click();

    await expect(page.getByTestId('audit-records-empty')).toContainText('No record matches');
  });

  test('says so when the result was truncated by the limit', async ({ page }) => {
    // A limit of 1 against a log that always has this UI's own reads in it.
    await page.getByTestId('audit-filter-limit').fill('1');
    await page.getByTestId('audit-read-btn').click();

    await expect(page.getByTestId('audit-truncated')).toContainText('More records matched');
  });

  test('starts the tail paused, streams, and stops cleanly', async ({ page }) => {
    // Paused by default: an idle tab must not hold a controller subscription.
    await expect(page.getByTestId('audit-tail-idle')).toBeVisible();
    await expect(page.getByTestId('audit-tail-toggle')).toContainText('Start tail');

    await page.getByTestId('audit-tail-toggle').click();
    await expect(page.getByTestId('audit-tail-toggle')).toContainText('Tailing');

    // Any audited action produces a record; reading is one.
    await page.getByTestId('audit-read-btn').click();
    await expect(page.getByTestId('audit-tail-records')).toContainText('"source":"ui"', {
      timeout: 15_000,
    });

    await page.getByTestId('audit-tail-toggle').click();
    await expect(page.getByTestId('audit-tail-idle')).toBeVisible();
  });
});
