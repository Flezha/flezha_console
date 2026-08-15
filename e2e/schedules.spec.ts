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

async function fillForm(page: Page, name: string, cron: string, factory: string) {
  await page.getByTestId('schedule-input-name').fill(name);
  await page.getByTestId('schedule-input-cron').fill(cron);
  await page.getByTestId('schedule-input-factory').fill(factory);
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
