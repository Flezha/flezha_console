import {
  comboboxValues,
  menuAction,
  test,
  expect,
  fillScheduleForm,
  openScheduleForm,
  removeSchedule,
  stopRelay,
  uniqueScheduleName,
  type Page,
} from './fixtures';

/**
 * The schedules screen against the dev controller, which validates the cron
 * and timezone and arms what it stores.
 *
 * The schedule a test creates is removed in `finally`, so a failure does not
 * leave a cron job firing; the relay a run starts runs the steps factory
 * `echo_steps`, and is stopped in `finally` too.
 */

/** The values a select offers, without its placeholder option. */
async function optionValues(page: Page, testid: string): Promise<string[]> {
  return comboboxValues(page, testid);
}

test.describe('Schedules', () => {
  test.beforeEach(async ({ live }) => {
    await live('/schedules');
  });

  test('the form offers what the controller reports and states what it refuses', async ({
    page,
  }) => {
    const name = uniqueScheduleName('pwc');
    await openScheduleForm(page);

    expect(await optionValues(page, 'schedule-input-namespace')).toContain('default');
    const factories = await optionValues(page, 'schedule-input-factory');
    expect(factories).toContain('echo_steps');
    // Only a steps factory can be scheduled, so a flow one is not offered.
    expect(factories).not.toContain('store_input');

    await fillScheduleForm(page, name, 'not a cron expression', 'echo_steps');
    // Which runner serves the chosen factory, at the point of choosing it.
    await expect(page.getByTestId('schedule-form-modal')).toContainText('Served by');
    await page.getByTestId('schedule-form-submit').click();
    await expect(page.getByTestId('schedule-form-error')).toContainText('cron');

    await page.getByTestId('schedule-input-cron').fill('*/5 * * * *');
    await page.getByTestId('schedule-input-timezone').fill('Mars/Olympus_Mons');
    await page.getByTestId('schedule-form-submit').click();
    await expect(page.getByTestId('schedule-form-error')).toContainText('timezone');

    // The form stays open and nothing was stored.
    await expect(page.getByTestId('schedule-form-modal')).toBeVisible();
    await page.getByTestId('schedule-form-cancel').click();
    await expect(page.getByTestId(`schedule-row-${name}`)).toHaveCount(0);
  });

  test('a schedule whose cron has no slot left is dormant, with no next fire', async ({ page }) => {
    const name = uniqueScheduleName('pwd');

    try {
      await openScheduleForm(page);
      // 30 February never comes, so the job finds no slot to arm.
      await fillScheduleForm(page, name, '0 0 30 2 *', 'echo_steps');
      await page.getByTestId('schedule-form-submit').click();
      await expect(page.getByTestId('schedule-form-modal')).toHaveCount(0);

      await expect(page.getByTestId(`schedule-status-${name}`)).toHaveText('Dormant');
      await expect(page.getByTestId(`schedule-next-fire-${name}`)).toHaveText('—');
    } finally {
      await removeSchedule(page, name);
    }
  });

  test('a schedule is armed with init values, runs now, and is removed', async ({
    page,
    live,
  }) => {
    const name = uniqueScheduleName('pwr');
    let started = '';

    try {
      await openScheduleForm(page);
      await fillScheduleForm(page, name, '0 3 * * *', 'echo_steps');
      await page.getByTestId('schedule-input-init-values').fill('{"greeting": "hello"}');
      await page.getByTestId('schedule-form-submit').click();
      await expect(page.getByTestId('schedule-form-modal')).toHaveCount(0);

      // Persisted *and* active: an entry the hub never accepted would read
      // "Inactive", which is the state this screen exists to distinguish.
      await expect(page.getByTestId(`schedule-status-${name}`)).toHaveText('Active');
      // Next fire is the slot the job is armed for, ahead of now with its date.
      await expect(page.getByTestId(`schedule-next-fire-${name}`)).toContainText(/\bin \d/);
      await expect(page.getByTestId(`schedule-next-fire-${name}`)).toContainText(/\d{4}-\d{2}-\d{2}/);
      await expect(page.getByTestId(`schedule-created-${name}`)).toContainText(/now|s ago/);

      const lastFire = page.getByTestId(`schedule-last-fire-${name}`);
      const firedBefore = (await lastFire.innerText()).trim();

      await menuAction(page, `schedule-menu-${name}`, `schedule-run-${name}`);
      await expect(page.getByTestId('schedule-run-modal')).toContainText(name);
      await page.getByTestId('schedule-run-confirm').click();

      const link = page.getByTestId('schedule-ran-link');
      await expect(page.getByTestId('schedule-ran')).toContainText(name);
      await expect(link).toContainText(`${name}@manual-`);
      started = (await link.innerText()).trim();

      // A manual run is not one of the schedule's cron fires, so its last
      // fire stays where it was.
      await expect(lastFire).toHaveText(firedBefore);

      // The link names the relay the run started, and reaches it.
      await link.click();
      await expect(page).toHaveURL(
        (url) => decodeURIComponent(url.pathname) === `/namespaces/default/relays/${started}`,
      );

      await live('/schedules');
      await menuAction(page, `schedule-menu-${name}`, `schedule-remove-${name}`);
      await expect(page.getByTestId('schedule-remove-modal')).toContainText(name);
      await page.getByTestId('schedule-remove-confirm').click();
      await expect(page.getByTestId(`schedule-row-${name}`)).toHaveCount(0);
    } finally {
      await removeSchedule(page, name);
      // In case the instance still waits for input.
      if (started) await stopRelay(page, started);
    }
  });
});
