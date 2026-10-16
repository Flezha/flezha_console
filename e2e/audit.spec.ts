import { test, expect, readFigure, type Page } from './fixtures';

/**
 * The audit log screen.
 *
 * Every assertion here is unconditional. `docker-compose.dev.yml` defaults
 * `FLEZHA_AUDIT_ENABLED` to `true`, so an unset flag is a broken stack, not a
 * reason to skip — the screen's disabled state, the statistics, the empty and
 * truncated reads are covered in `test/flezha_ui_web/live/audit_live_test.exs`,
 * where they can be produced on demand.
 */

/** The rotated files the catalog lists, by name. */
const fileNames = (page: Page) =>
  page.getByTestId('audit-file').evaluateAll((rows) =>
    rows.map((row) => (row.querySelector('span')?.textContent ?? '').trim()),
  );

test.describe('Audit log', () => {
  test.beforeEach(async ({ live }) => {
    await live('/audit');
  });

  test('a read shows the records, and the name filter narrows them to that name', async ({ page }) => {
    await expect(
      page.getByTestId('audit-disabled'),
      'audit must be enabled on the controller — check FLEZHA_AUDIT_ENABLED',
    ).toHaveCount(0);

    await page.getByTestId('audit-read-btn').click();
    // Reading the audit log is itself audited, so there is always at least
    // this UI's own activity to find.
    await expect(page.getByTestId('audit-records')).toContainText('"source":"ui"');

    const first = page.getByTestId('audit-records').locator('> *').first();
    const name = JSON.parse((await first.innerText()).trim()).name as string;

    await page.getByTestId('audit-filter-name').fill(name);
    await page.getByTestId('audit-read-btn').click();
    const records = page.getByTestId('audit-records').locator('> *');
    await expect(records.filter({ hasNotText: `"name":"${name}"` })).toHaveCount(0);
    await expect(records).not.toHaveCount(0);
  });

  test('the file filter reads one closed file, and an unknown file is refused by name', async ({
    page,
  }) => {
    // Other workers rotate too, so the file this rotation closed is told apart
    // by name; a closed file's record count no longer changes.
    const before = new Set(await fileNames(page));
    await page.getByTestId('audit-rotate-btn').click();
    await expect(page.locator('body')).toContainText('Audit log rotated');

    let filename = '';
    await expect
      .poll(async () => (filename = (await fileNames(page)).find((name) => !before.has(name)) ?? ''))
      .not.toBe('');

    const file = page.getByTestId('audit-file').filter({ hasText: filename });
    const recorded = await readFigure(file.locator('td').nth(1));

    // A file that closed after a long quiet holds more than the read's limit.
    const limit = 1000;
    await page.getByTestId('audit-filter-file').fill(filename);
    await page.getByTestId('audit-filter-limit').fill(String(limit));
    await page.getByTestId('audit-read-btn').click();
    await expect(page.getByTestId('audit-records').locator('> *')).toHaveCount(Math.min(recorded, limit));

    await page.getByTestId('audit-filter-file').fill('no-such-audit-file.log');
    await page.getByTestId('audit-read-btn').click();
    await expect(page.getByTestId('runtime-error')).toContainText('audit.file_not_found');
    await expect(page.getByTestId('audit-records')).toHaveCount(0);
    await expect(page.getByTestId('audit-records-empty')).toHaveCount(0);
  });

  test('the tail starts paused, streams an administration action as it is audited, and stops', async ({
    page,
  }) => {
    // Paused by default: an idle tab must not hold a controller subscription.
    await expect(page.getByTestId('audit-tail-idle')).toBeVisible();
    await expect(page.getByTestId('audit-tail-toggle')).toHaveAttribute('aria-checked', 'false');

    await page.getByTestId('audit-tail-toggle').click();
    await expect(page.getByTestId('audit-tail-toggle')).toHaveAttribute('aria-checked', 'true');

    await page.getByTestId('audit-rotate-btn').click();
    await expect(page.locator('body')).toContainText('Audit log rotated');
    await expect(page.getByTestId('audit-tail-records')).toContainText('rotate');

    await page.getByTestId('audit-tail-toggle').click();
    await expect(page.getByTestId('audit-tail-idle')).toBeVisible();
  });
});
