import { test, expect } from './fixtures';

/**
 * Observability sources and sinks, and the toggle round-trip.
 *
 * The source toggled here is restored in the same test: the suite shares one
 * controller, and a source left disabled would silently change what every
 * later assertion — and the dev stack itself — can see.
 */
test.describe('Observability', () => {
  const SOURCE = 'flezha_convergence';

  test.beforeEach(async ({ live }) => {
    await live('/observability');
  });

  test('lists sources and sinks with their state', async ({ page }) => {
    await expect(page.getByTestId('sources-panel')).toBeVisible();
    await expect(page.getByTestId('sinks-panel')).toBeVisible();

    await expect(page.getByTestId(`source-${SOURCE}`)).toBeVisible();
    await expect(page.getByTestId(`source-enabled-${SOURCE}`)).toHaveText(/enabled|disabled/);

    // A sink carries a pid rather than an enabled flag, so it reports running.
    const sinkStates = page.locator('[data-testid^="sink-running-"]');
    await expect(sinkStates.first()).toHaveText(/running|not running/);
  });

  test('a source toggles and the listing reflects it', async ({ page }) => {
    const state = page.getByTestId(`source-enabled-${SOURCE}`);
    const toggle = page.getByTestId(`toggle-${SOURCE}`);

    const before = (await state.innerText()).trim();
    const opposite = before === 'enabled' ? 'disabled' : 'enabled';

    await toggle.click();
    await expect(state).toHaveText(opposite);

    // Put it back, so the stack is as this spec found it.
    await toggle.click();
    await expect(state).toHaveText(before);
  });

  test('a tail can be started and stopped', async ({ page }) => {
    await page.getByTestId(`tail-${SOURCE}`).click();

    const panel = page.getByTestId('tail-panel');
    await expect(panel).toBeVisible();
    await expect(panel).toContainText(SOURCE);

    await page.getByTestId('stop-tail').click();
    await expect(page.getByTestId('stop-tail')).toHaveCount(0);
  });
});
