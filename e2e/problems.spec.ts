import { test, expect } from './fixtures';

/**
 * The open problems screen and the rail's count of it, against the dev stack.
 *
 * Which problems a fleet has depends on the moment it is read, so this holds
 * the count and the list to one answer rather than naming a problem; what each
 * kind of problem says and offers, and their order, are asserted against
 * arranged fleets in `test/flezha_console_web/live/problems_live_test.exs`.
 */
test.describe('Open problems', () => {
  test('the rail leads to the screen, and counts what it lists', async ({ page, live }) => {
    await live('/cluster');
    await page.locator('.flz-sidebar-nav a[href="/problems"]').click();
    await expect(page).toHaveURL(/\/problems$/);

    await expect(page.getByTestId('problems-loading')).toHaveCount(0);
    await expect(page.getByTestId('runtime-error')).toHaveCount(0);

    // Read in one go: the rail and the list render from the same pulse, so a
    // read split across two renders could catch them on different pulses.
    const seen = await page.evaluate(() => ({
      listed: document.querySelectorAll('[data-testid^="problem-"][data-severity]').length,
      rail: document.querySelector('[data-testid="problems-count"]')?.textContent?.trim() ?? null,
      clear: document.querySelector('[data-testid="problems-clear"]') !== null,
    }));

    expect(seen).toEqual({
      listed: seen.listed,
      rail: seen.listed === 0 ? null : String(seen.listed),
      clear: seen.listed === 0,
    });
  });
});
