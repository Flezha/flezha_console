import { test, expect } from './fixtures';

/**
 * The open problems screen and the rail's count of it, against the dev stack.
 *
 * Which problems a fleet has depends on the moment it is read, so this holds
 * the count and the list to one answer rather than naming a problem; what each
 * kind of problem says and offers is asserted against arranged fleets in
 * `test/flezha_ui_web/live/problems_live_test.exs`.
 */
test.describe('Open problems', () => {
  test('the rail leads to the screen, and counts what it lists', async ({ page, live }) => {
    await live('/cluster');
    await page.locator('.flz-sidebar-nav a[href="/problems"]').click();
    await expect(page).toHaveURL(/\/problems$/);

    await expect(page.getByTestId('problems-loading')).toHaveCount(0);
    const items = page.locator('[data-testid^="problem-"][data-severity]');

    await expect(async () => {
      const listed = await items.count();

      if (listed === 0) {
        await expect(page.getByTestId('problems-clear')).toBeVisible();
        await expect(page.getByTestId('problems-count')).toHaveCount(0);
      } else {
        await expect(page.getByTestId('problems-count')).toHaveText(String(listed));
      }
    }).toPass({ timeout: 15_000 });
  });

  test('worst first: no warning is listed above a failure', async ({ page, live }) => {
    await live('/problems');
    await expect(page.getByTestId('problems-loading')).toHaveCount(0);

    const severities = await page
      .locator('[data-testid^="problem-"][data-severity]')
      .evaluateAll((els) => els.map((el) => el.getAttribute('data-severity')));

    const firstWarning = severities.indexOf('warning');
    const lastNegative = severities.lastIndexOf('negative');
    expect(firstWarning === -1 || lastNegative < firstWarning).toBe(true);
  });
});
