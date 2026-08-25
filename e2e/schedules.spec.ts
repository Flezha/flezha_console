import { test, expect, type Page } from './fixtures';

/**
 * The schedules screen.
 *
 * Each test removes the schedule it created, so a failure does not leave a
 * cron job firing against the dev controller.
 */

/**
 * Unique per run, so a leftover from a failed run cannot collide.
 *
 * Kept short deliberately: the controller allows 11 bytes, because the cron
 * instance id it composes (`<name>@<slot-iso>`) must fit the 32-byte operative
 * id limit.
 */
function uniqueScheduleName(prefix = 'pw'): string {
  return `${prefix}${Date.now().toString(36).slice(-6)}`;
}

async function openForm(page: Page) {
  await page.getByTestId('schedule-new-btn').click();
  await expect(page.getByTestId('schedule-form-modal')).toBeVisible();
}

/**
 * Fills the form, choosing the factory rather than typing it.
 *
 * The target's namespace and factory are now offered from what the controller
 * reports, so a spec that typed an id would be exercising a path only an
 * unreachable controller reaches.
 */
async function fillForm(page: Page, name: string, cron: string, factory: string) {
  await page.getByTestId('schedule-input-name').fill(name);
  await page.getByTestId('schedule-input-cron').fill(cron);
  await page.getByTestId('schedule-input-namespace').selectOption('default');
  await page.getByTestId('schedule-input-factory').selectOption(factory);
}

/**
 * Cleanup, so a failure does not leave a cron job armed.
 *
 * Tolerating an already-removed schedule is what makes this safe to call from
 * `finally` after the test removed it itself; it never skips an assertion.
 */
async function removeSchedule(page: Page, name: string) {
  const row = page.getByTestId(`schedule-row-${name}`);
  if ((await row.count()) === 0) return;

  await page.getByTestId(`schedule-remove-${name}`).click();
  await page.getByTestId('schedule-remove-confirm').click();
  await expect(row).toHaveCount(0);
}

/** The values a select offers, without its placeholder option. */
async function optionValues(page: Page, testid: string): Promise<string[]> {
  return page
    .getByTestId(testid)
    .locator('option')
    .evaluateAll((opts) =>
      opts.map((o) => (o as HTMLOptionElement).value).filter((v) => v !== ''),
    );
}

test.describe('Schedules', () => {
  test.beforeEach(async ({ live }) => {
    await live('/schedules');
  });

  test('creates a schedule, arms it, and shows when it next fires', async ({ page }) => {
    const name = uniqueScheduleName();

    try {
      await openForm(page);
      await fillForm(page, name, '*/5 * * * *', 'echo_workflow');
      await page.getByTestId('schedule-form-submit').click();

      await expect(page.getByTestId('schedule-form-modal')).toHaveCount(0);
      await expect(page.getByTestId(`schedule-row-${name}`)).toBeVisible();

      // Persisted *and* armed: an entry the hub never accepted would read
      // "Not armed", which is the state this screen exists to distinguish.
      await expect(page.getByTestId(`schedule-status-${name}`)).toContainText('Armed');

      // Next fire is computed from the cron, not reported by the hub.
      await expect(page.getByTestId(`schedule-next-fire-${name}`)).toHaveText(
        /\d{4}-\d{2}-\d{2}/,
      );
    } finally {
      await removeSchedule(page, name);
    }
  });

  test('rejects an invalid cron expression without persisting anything', async ({ page }) => {
    const name = uniqueScheduleName('pwc');

    await openForm(page);
    await fillForm(page, name, 'not a cron expression', 'echo_workflow');
    await page.getByTestId('schedule-form-submit').click();

    await expect(page.getByTestId('schedule-form-error')).toContainText('cron');

    // The form stays open and nothing was stored.
    await expect(page.getByTestId('schedule-form-modal')).toBeVisible();
    await page.getByTestId('schedule-form-cancel').click();
    await expect(page.getByTestId(`schedule-row-${name}`)).toHaveCount(0);
  });

  test('rejects an unknown timezone without persisting anything', async ({ page }) => {
    const name = uniqueScheduleName('pwt');

    await openForm(page);
    await fillForm(page, name, '*/5 * * * *', 'echo_workflow');
    await page.getByTestId('schedule-input-timezone').fill('Mars/Olympus_Mons');
    await page.getByTestId('schedule-form-submit').click();

    await expect(page.getByTestId('schedule-form-error')).toContainText('timezone');

    await page.getByTestId('schedule-form-cancel').click();
    await expect(page.getByTestId(`schedule-row-${name}`)).toHaveCount(0);
  });

  test('requires the fields the controller requires', async ({ page }) => {
    await openForm(page);
    await page.getByTestId('schedule-input-name').fill('');
    await page.getByTestId('schedule-form-submit').click();

    await expect(page.getByTestId('schedule-form-error')).toContainText('Required');
    await page.getByTestId('schedule-form-cancel').click();
  });

  test('offers the namespaces and factories the controller reports', async ({ page }) => {
    await openForm(page);

    const namespaces = await optionValues(page, 'schedule-input-namespace');
    expect(namespaces).toContain('default');

    const factories = await optionValues(page, 'schedule-input-factory');
    expect(factories, 'at least one factory should be offered').toContain('echo_workflow');

    // Which runner serves the chosen factory, at the point of choosing it.
    await page.getByTestId('schedule-input-factory').selectOption('echo_workflow');
    await expect(page.getByTestId('schedule-form-modal')).toContainText('Served by');

    await page.getByTestId('schedule-form-cancel').click();
  });

  test('confirm-gates removal', async ({ page }) => {
    const name = uniqueScheduleName('pwr');

    try {
      await openForm(page);
      await fillForm(page, name, '*/5 * * * *', 'echo_workflow');
      await page.getByTestId('schedule-form-submit').click();
      await expect(page.getByTestId(`schedule-row-${name}`)).toBeVisible();

      // Dismissing the confirmation must leave the schedule armed.
      await page.getByTestId(`schedule-remove-${name}`).click();
      await expect(page.getByTestId('schedule-remove-modal')).toBeVisible();
      await page.getByTestId('schedule-remove-cancel').click();
      await expect(page.getByTestId('schedule-remove-modal')).toHaveCount(0);
      await expect(page.getByTestId(`schedule-row-${name}`)).toBeVisible();

      // Confirming removes it.
      await page.getByTestId(`schedule-remove-${name}`).click();
      await page.getByTestId('schedule-remove-confirm').click();
      await expect(page.getByTestId(`schedule-row-${name}`)).toHaveCount(0);
    } finally {
      await removeSchedule(page, name);
    }
  });
});
