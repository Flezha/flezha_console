import { test, expect } from './fixtures';

/**
 * Observability sources and sinks, and a live tail of one, against the real
 * controller.
 *
 * Toggling a source is controller-wide and asks for no confirmation, so it is
 * covered in `test/flezha_ui_web/live/observability_live_test.exs` alone, as is
 * how the tail renders what it receives.
 */
test.describe('Observability', () => {
  test('lists sources and sinks, and a tail receives the source’s signals while started and nothing once stopped', async ({
    page,
    live,
  }) => {
    await live('/observability');

    await expect(page.getByTestId('sources-panel')).toBeVisible();
    await expect(page.getByTestId('sinks-panel')).toBeVisible();
    await expect(page.getByTestId('source-enabled-flezha_convergence')).toHaveAttribute(
      'data-enabled',
      /^(true|false)$/,
    );
    // A sink carries a pid rather than an enabled flag, so it reports running.
    await expect(page.locator('[data-testid^="sink-running-"]').first()).toHaveText(
      /^\s*(Running|Not running)\s*$/,
    );

    // The VM reports its schedulers, ports and processes on every sample.
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
    await expect(records.first()).toContainText('beam_vm.');

    await page.getByTestId('stop-tail').click();
    await expect(panel).toHaveCount(0);
    await expect(records).toHaveCount(0);
    await expect(button).toHaveAttribute('aria-pressed', 'false');
  });
});
