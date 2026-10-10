import {
  test,
  expect,
  fillScheduleForm,
  openScheduleForm,
  removeSchedule,
  uniqueScheduleName,
  type Page,
} from './fixtures';

/**
 * The schedules screen.
 *
 * Each test removes the schedule it created, so a failure does not leave a
 * cron job firing against the dev controller.
 */

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
      await openScheduleForm(page);
      await fillScheduleForm(page, name, '*/5 * * * *', 'echo_steps');
      await page.getByTestId('schedule-form-submit').click();

      await expect(page.getByTestId('schedule-form-modal')).toHaveCount(0);
      await expect(page.getByTestId(`schedule-row-${name}`)).toBeVisible();

      // Persisted *and* active: an entry the hub never accepted would read
      // "Inactive", which is the state this screen exists to distinguish.
      await expect(page.getByTestId(`schedule-status-${name}`)).toHaveText('Active');

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

    await openScheduleForm(page);
    await fillScheduleForm(page, name, 'not a cron expression', 'echo_steps');
    await page.getByTestId('schedule-form-submit').click();

    await expect(page.getByTestId('schedule-form-error')).toContainText('cron');

    // The form stays open and nothing was stored.
    await expect(page.getByTestId('schedule-form-modal')).toBeVisible();
    await page.getByTestId('schedule-form-cancel').click();
    await expect(page.getByTestId(`schedule-row-${name}`)).toHaveCount(0);
  });

  test('rejects an unknown timezone without persisting anything', async ({ page }) => {
    const name = uniqueScheduleName('pwt');

    await openScheduleForm(page);
    await fillScheduleForm(page, name, '*/5 * * * *', 'echo_steps');
    await page.getByTestId('schedule-input-timezone').fill('Mars/Olympus_Mons');
    await page.getByTestId('schedule-form-submit').click();

    await expect(page.getByTestId('schedule-form-error')).toContainText('timezone');

    await page.getByTestId('schedule-form-cancel').click();
    await expect(page.getByTestId(`schedule-row-${name}`)).toHaveCount(0);
  });

  test('passes init values as JSON, and refuses JSON that is not an object', async ({ page }) => {
    const name = uniqueScheduleName('pwi');

    try {
      await openScheduleForm(page);
      await fillScheduleForm(page, name, '*/5 * * * *', 'echo_steps');
      await page.getByTestId('schedule-input-init-values').fill('not json');
      await page.getByTestId('schedule-form-submit').click();
      await expect(page.getByTestId('schedule-form-error')).toBeVisible();
      await expect(page.getByTestId('schedule-form-modal')).toBeVisible();

      await page.getByTestId('schedule-input-init-values').fill('{"greeting": "hello"}');
      await page.getByTestId('schedule-form-submit').click();
      await expect(page.getByTestId('schedule-form-modal')).toHaveCount(0);
      await expect(page.getByTestId(`schedule-status-${name}`)).toHaveText('Active');
      await expect(page.getByTestId('schedule-table')).toContainText(name);
    } finally {
      await removeSchedule(page, name);
    }
  });

  test('requires the fields the controller requires', async ({ page }) => {
    await openScheduleForm(page);
    await page.getByTestId('schedule-input-name').fill('');
    await page.getByTestId('schedule-form-submit').click();

    await expect(page.getByTestId('schedule-form-error')).toContainText('Required');
    await page.getByTestId('schedule-form-cancel').click();
  });

  test('offers the namespaces and factories the controller reports', async ({ page }) => {
    await openScheduleForm(page);

    const namespaces = await optionValues(page, 'schedule-input-namespace');
    expect(namespaces).toContain('default');

    const factories = await optionValues(page, 'schedule-input-factory');
    expect(factories, 'at least one factory should be offered').toContain('echo_steps');
    // Only a steps factory can be scheduled, so a flow one is not offered.
    expect(factories, 'a flow factory must not be offered').not.toContain('store_input');

    // Which runner serves the chosen factory, at the point of choosing it.
    await page.getByTestId('schedule-input-factory').selectOption('echo_steps');
    await expect(page.getByTestId('schedule-form-modal')).toContainText('Served by');

    await page.getByTestId('schedule-form-cancel').click();
  });

  test('confirm-gates removal', async ({ page }) => {
    const name = uniqueScheduleName('pwr');

    try {
      await openScheduleForm(page);
      await fillScheduleForm(page, name, '*/5 * * * *', 'echo_steps');
      await page.getByTestId('schedule-form-submit').click();
      await expect(page.getByTestId(`schedule-row-${name}`)).toBeVisible();

      // Dismissing the confirmation must leave the schedule active.
      await page.getByTestId(`schedule-remove-${name}`).click();
      await expect(page.getByTestId('schedule-remove-modal')).toBeVisible();
      await page.getByTestId('schedule-remove-cancel').click();
      await expect(page.getByTestId('schedule-remove-modal')).toHaveCount(0);
      await expect(page.getByTestId(`schedule-row-${name}`)).toBeVisible();
      await expect(page.getByTestId(`schedule-status-${name}`)).toHaveText('Active');

      // Confirming removes it.
      await page.getByTestId(`schedule-remove-${name}`).click();
      await page.getByTestId('schedule-remove-confirm').click();
      await expect(page.getByTestId(`schedule-row-${name}`)).toHaveCount(0);
    } finally {
      await removeSchedule(page, name);
    }
  });
});
