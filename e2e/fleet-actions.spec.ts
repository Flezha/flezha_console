import {
  menuAction,
  test,
  expect,
  fillScheduleForm,
  openScheduleForm,
  removeSchedule,
  startRelay,
  stopRelay,
  uniqueId,
  uniqueScheduleName,
  openPage,
  type Page,
} from './fixtures';

/**
 * The fleet-wide actions and facts this console added: a runner's OS pid, a
 * schedule run now, the audit log rotated, and the relay lifecycle feed.
 *
 * The schedule a test creates is removed in `finally`; the relay it fires runs
 * the steps factory `echo_steps`, and is stopped in `finally` too. The relay the
 * feed test starts is stopped by the test itself.
 */
test.describe('Fleet actions', () => {
  test('each runner states its OS pid', async ({ page, live }) => {
    await live('/cluster');

    const pid = page.locator('[data-testid^="os-pid-"]').first();
    // The runner reaches the controller across containers, where the socket
    // cannot say which process is on the other end.
    await expect(pid).toHaveText(/^\s*—\s*$/);
  });

  test('a schedule runs now and names the relay it started', async ({ page, live }) => {
    const name = uniqueScheduleName('pwr');
    let started = '';
    await live('/schedules');

    try {
      await openScheduleForm(page);
      await fillScheduleForm(page, name, '0 3 * * *', 'echo_steps');
      await page.getByTestId('schedule-form-submit').click();
      await expect(page.getByTestId(`schedule-row-${name}`)).toBeVisible();

      const lastFire = page.getByTestId(`schedule-last-fire-${name}`);
      const firedBefore = (await lastFire.innerText()).trim();

      await menuAction(page, `schedule-menu-${name}`, `schedule-run-${name}`);
      await expect(page.getByTestId('schedule-run-modal')).toContainText(name);
      await page.getByTestId('schedule-run-confirm').click();

      const link = page.getByTestId('schedule-ran-link');
      await expect(page.getByTestId('schedule-ran')).toContainText(name);
      await expect(link).toContainText(`${name}@manual-`);
      await expect(link).toHaveAttribute('href', /\/namespaces\/default\/relays\//);
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
    } finally {
      await removeSchedule(page, name);
      // The instance waits for input like any steps relay, so it is stopped.
      if (started) {
        await live('/namespaces/default');
        await stopRelay(page, started);
      }
    }
  });

  test('the audit log rotates and the closed file is listed', async ({ page, live }) => {
    await live('/audit');

    const files = page.getByTestId('audit-file');
    const before = await files.count();

    await page.getByTestId('audit-rotate-btn').click();

    await expect(page.locator('body')).toContainText('Audit log rotated');
    await expect(files).toHaveCount(before + 1);
  });

  test('a relay starting and stopping appears in the lifecycle feed', async ({ page, live }) => {
    const id = uniqueId('pw_feed');
    await live('/namespaces/default/relays');
    // The feed holds what arrives while the index is open, so the stop is made
    // from a second tab while this one watches.
    let other: Page | undefined;

    try {
      await startRelay(page, id, { run: 'flow', namespace: 'default' });

      const feed = page.getByTestId('lifecycle-feed');
      await expect(
        feed.locator('li').filter({ hasText: id }).filter({ hasText: 'started from store_input' }),
      ).toHaveCount(1, { timeout: 15_000 });

      other = await openPage(page, '/namespaces/default');
      await stopRelay(other, id);

      await expect(
        feed.locator('li').filter({ hasText: id }).filter({ hasText: 'stopped:' }),
      ).toHaveCount(1, { timeout: 15_000 });
      await expect(page.getByTestId(`relay-index-row-${id}`)).toHaveCount(0);
    } finally {
      await other?.close();
      await live('/namespaces/default');
      await stopRelay(page, id);
    }
  });
});
