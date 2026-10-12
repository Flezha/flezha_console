import { test, expect, readFigure, ADVANCE_WINDOW_MS } from './fixtures';

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

  test('the name filter narrows the records to that name', async ({ page }) => {
    await page.getByTestId('audit-read-btn').click();
    const first = page.getByTestId('audit-records').locator('> *').first();
    const name = JSON.parse((await first.innerText()).trim()).name as string;

    await page.getByTestId('audit-filter-name').fill(name);
    await page.getByTestId('audit-read-btn').click();
    const records = page.getByTestId('audit-records').locator('> *');
    await expect(records.filter({ hasNotText: `"name":"${name}"` })).toHaveCount(0);
    await expect(records).not.toHaveCount(0);

    await page.getByTestId('audit-filter-name').fill('no_such_name');
    await page.getByTestId('audit-read-btn').click();
    await expect(page.getByTestId('audit-records-empty')).toContainText('No record matches');
  });

  test('the file filter reads one closed file, and an unknown file is refused by name', async ({
    page,
  }) => {
    // Rotation closes the current file, so there is always a file to name.
    await page.getByTestId('audit-rotate-btn').click();
    await expect(page.locator('body')).toContainText('Audit log rotated');
    const file = page.getByTestId('audit-file').last();
    const filename = (await file.locator('span').first().innerText()).trim();
    const recorded = await readFigure(file.locator('td').nth(1));

    await page.getByTestId('audit-filter-file').fill(filename);
    await page.getByTestId('audit-filter-limit').fill('1000');
    await page.getByTestId('audit-read-btn').click();
    await expect(page.getByTestId('audit-records').locator('> *')).toHaveCount(recorded);

    await page.getByTestId('audit-filter-file').fill('no-such-audit-file.log');
    await page.getByTestId('audit-read-btn').click();
    await expect(page.getByTestId('runtime-error')).toContainText('audit.file_not_found');
    await expect(page.getByTestId('audit-records')).toHaveCount(0);
    await expect(page.getByTestId('audit-records-empty')).toHaveCount(0);
  });

  test('the tail shows an administration action as it is audited', async ({ page }) => {
    await page.getByTestId('audit-tail-toggle').click();
    await expect(page.getByTestId('audit-tail-toggle')).toHaveAttribute('aria-checked', 'true');

    await page.getByTestId('audit-rotate-btn').click();
    await expect(page.locator('body')).toContainText('Audit log rotated');
    await expect(page.getByTestId('audit-tail-records')).toContainText('rotate', {
      timeout: ADVANCE_WINDOW_MS,
    });

    await page.getByTestId('audit-tail-toggle').click();
  });

  test('starts the tail paused, streams, and stops cleanly', async ({ page }) => {
    // Paused by default: an idle tab must not hold a controller subscription.
    await expect(page.getByTestId('audit-tail-idle')).toBeVisible();
    await expect(page.getByTestId('audit-tail-toggle')).toHaveAttribute('aria-checked', 'false');

    await page.getByTestId('audit-tail-toggle').click();
    await expect(page.getByTestId('audit-tail-toggle')).toHaveAttribute('aria-checked', 'true');

    // Any audited action produces a record; reading is one.
    await page.getByTestId('audit-read-btn').click();
    await expect(page.getByTestId('audit-tail-records')).toContainText('"source":"ui"', {
      timeout: 15_000,
    });

    await page.getByTestId('audit-tail-toggle').click();
    await expect(page.getByTestId('audit-tail-idle')).toBeVisible();
  });
});
