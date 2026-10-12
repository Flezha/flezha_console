import { test, expect, ADVANCE_WINDOW_MS, expectAdvances } from './fixtures';

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
    await expect(page.getByTestId(`source-enabled-${SOURCE}`)).toHaveAttribute('data-enabled', /^(true|false)$/);

    // A sink carries a pid rather than an enabled flag, so it reports running.
    const sinkStates = page.locator('[data-testid^="sink-running-"]');
    await expect(sinkStates.first()).toHaveText(/^\s*(Running|Not running)\s*$/);
  });

  test('a source toggles and the listing reflects it', async ({ page }) => {
    const state = page.getByTestId(`source-enabled-${SOURCE}`);
    const toggle = page.getByTestId(`toggle-${SOURCE}`);

    const before = (await state.getAttribute('data-enabled'))!;
    const opposite = before === 'true' ? 'false' : 'true';

    await toggle.click();
    await expect(state).toHaveAttribute('data-enabled', opposite);
    await expect(toggle).toHaveAttribute('aria-checked', opposite);

    // Put it back, so the stack is as this spec found it.
    await toggle.click();
    await expect(state).toHaveAttribute('data-enabled', before);
  });

  test('a tail receives the source’s signals while started and nothing once stopped', async ({
    page,
  }) => {
    // The VM reports its schedulers, ports and processes on every sample, so
    // a live tail of it fills.
    const button = page.getByTestId('tail-beam_vm');
    await button.click();

    // The tail opens beside the listing at once, wherever the source sat, and
    // its row's button says it is running.
    const panel = page.getByTestId('tail-panel');
    await expect(panel).toBeInViewport();
    await expect(panel).toContainText('beam_vm');
    await expect(button).toHaveAttribute('aria-pressed', 'true');
    await expect(button).toContainText('Stop tail');

    const records = page.getByTestId('tail-record');
    await expect(records.first()).toContainText('beam_vm.', { timeout: ADVANCE_WINDOW_MS });
    await expectAdvances(() => records.count(), 'the tail');

    await page.getByTestId('stop-tail').click();
    await expect(page.getByTestId('tail-panel')).toHaveCount(0);
    await expect(records).toHaveCount(0);
    await expect(button).toHaveAttribute('aria-pressed', 'false');
  });
});
