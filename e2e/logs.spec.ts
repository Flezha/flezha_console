import { test, expect, growListing, type Page } from './fixtures';

/**
 * The Logs screen, one tab per log kind the controller declares.
 *
 * Every assertion here is unconditional. `docker-compose.dev.yml` defaults
 * `FLEZHA_AUDIT_ENABLED` to `true`, so an unset flag is a broken stack, not a
 * reason to skip — a switched-off kind, a refused read, Read more and its cap
 * are covered in `test/flezha_console_web/live/logs_live_test.exs`, where they
 * can be produced on demand. The relay history's sentences are in
 * `relay-history.spec.ts`.
 */

const CONTROLLER = 'flezha@flezha_controller';

/** The ids of the connected controller's files the listing shows, every page of it shown. */
const fileIds = async (page: Page) => {
  await growListing(page, 'logs-file-rows');
  return page
    .locator(`[id^="logs-file-${CONTROLLER}-"]`)
    .evaluateAll((rows) => rows.map((row) => row.id));
};

const query = (page: Page, key: string) => new URL(page.url()).searchParams.get(key);

test.describe('Logs', () => {
  test('the old audit address opens the audit tab, keeping its query', async ({ page, live }) => {
    await live('/audit?name=read');

    await expect(page).toHaveURL(/\/logs\/audit\?name=read$/);
    await expect(page.getByTestId('logs-tab-audit')).toHaveAttribute('aria-current', 'page');
    await expect(page.getByTestId('logs-filter-name')).toHaveValue('read');
  });

  test('a tab patches the address to its kind, on the same page', async ({ page, live }) => {
    await live('/logs/audit');
    await expect(
      page.getByTestId('logs-disabled'),
      'audit must be enabled on the controller — check FLEZHA_AUDIT_ENABLED',
    ).toHaveCount(0);

    // A patch keeps the page: a full load would drop this marker.
    await page.evaluate(() => ((window as any).__logsTabs = true));

    await page.getByTestId('logs-tab-relay_history').click();
    await expect(page).toHaveURL(/\/logs\/relay_history$/);
    await expect(page.getByTestId('logs-tab-relay_history')).toHaveAttribute('aria-current', 'page');
    await expect(page.getByTestId('logs-tab-audit')).not.toHaveAttribute('aria-current', 'page');
    await expect(page.getByTestId('logs-filter-relay')).toBeVisible();
    expect(await page.evaluate(() => (window as any).__logsTabs)).toBe(true);
  });

  test('a filter rides the address and survives a reload', async ({ page, live }) => {
    await live('/logs/audit');
    const records = page.getByTestId('log-record');
    await expect(records).not.toHaveCount(0);

    // A record opens in place to the whole of it. The head's direct spans are
    // its time, then the declared columns: source, name, …
    const head = page.getByTestId('log-record-head').first();
    const name = (await head.locator(':scope > span').nth(2).innerText()).trim();
    await head.click();
    await expect(page.getByTestId('log-record-json').first()).toContainText(`"name": "${name}"`);

    await page.getByTestId('logs-filter-name').fill(name);
    await page.getByTestId('logs-read-btn').click();
    await expect.poll(() => query(page, 'name')).toBe(name);

    const url = new URL(page.url());
    await live(url.pathname + url.search);
    await expect(page.getByTestId('logs-filter-name')).toHaveValue(name);
    await expect(records).not.toHaveCount(0);
    await expect(
      page.getByTestId('log-record-head').locator(':scope > span:nth-child(3)').filter({ hasNotText: name }),
    ).toHaveCount(0);
  });

  test("rotating the connected controller's current file lists the file it closed", async ({
    page,
    live,
  }) => {
    await live('/logs/audit');
    // The kinds load in the background; the listing is read once they have.
    const rotate = page.getByTestId(`logs-rotate-${CONTROLLER}`);
    await expect(rotate).toBeVisible();

    // Other workers rotate too, so the file this rotation closed is told apart
    // by its id: controller and name.
    const before = new Set(await fileIds(page));
    await rotate.click();
    await expect(page.locator('body')).toContainText(`${CONTROLLER} started a new file`);

    let closed = '';
    await expect
      .poll(async () => (closed = (await fileIds(page)).find((id) => !before.has(id) && !id.endsWith('-current.jsonl')) ?? ''))
      .not.toBe('');

    const filename = closed.slice(`logs-file-${CONTROLLER}-`.length);
    const row = page.locator(`[id="${closed}"]`);
    await expect(row).toContainText(filename);
    await expect(row).not.toContainText('current');
  });

  test('the tail starts paused, streams an action as it is audited, and stops', async ({ page, live }) => {
    await live('/logs/audit');

    // Paused by default: an idle tab must not hold a controller subscription.
    await expect(page.getByTestId('logs-tail-idle')).toBeVisible();
    await expect(page.getByTestId('logs-tail-toggle')).toHaveAttribute('aria-checked', 'false');

    await page.getByTestId('logs-tail-toggle').click();
    await expect(page.getByTestId('logs-tail-toggle')).toHaveAttribute('aria-checked', 'true');

    await page.getByTestId(`logs-rotate-${CONTROLLER}`).click();
    await expect(page.locator('body')).toContainText(`${CONTROLLER} started a new file`);
    await expect(page.getByTestId('logs-tail-records')).toContainText('rotate');

    await page.getByTestId('logs-tail-toggle').click();
    await expect(page.getByTestId('logs-tail-idle')).toBeVisible();
  });
});
