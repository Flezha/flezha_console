import { test, expect } from './fixtures';

/**
 * Observability sources, what they said recently, and a tail of one, against
 * the real controller.
 *
 * Toggling a source is controller-wide and asks for no confirmation, so it is
 * covered in `test/flezha_ui_web/live/observability_live_test.exs` alone, as is
 * how the tail renders what it receives.
 */
test.describe('Observability', () => {
  test('every source says what it is and what it said recently; none that cannot speak is listed', async ({
    page,
    live,
  }) => {
    await live('/observability');

    await expect(page.getByTestId('sources-panel')).toBeVisible();
    await expect(page.getByTestId('sinks-line')).toContainText('live tails');
    await expect(page.getByTestId('source-description-beam_vm')).toContainText('Erlang VM');
    // The VM reports on every poll, so it always has something recent to say.
    await expect(page.getByTestId('source-activity-beam_vm')).toContainText(/×\S+ .* last \S+ ago/);
    await expect(page.getByTestId('source-group-machine')).toBeVisible();

    for (const gone of ['flezha_reconcile', 'flezha_leadership', 'flezha_bounded_mailbox']) {
      await expect(page.getByTestId(`source-${gone}`)).toHaveCount(0);
    }
  });

  test('a tail opens with recent history, adds live signals above it, and stops', async ({ page, live }) => {
    await live('/observability');

    const button = page.getByTestId('tail-beam_vm');
    await button.click();

    // The tail opens beside the listing at once, wherever the source sat.
    const panel = page.getByTestId('tail-panel');
    await expect(panel).toBeInViewport();
    await expect(panel).toContainText('beam_vm');
    await expect(button).toHaveAttribute('aria-pressed', 'true');
    await expect(button).toContainText('Stop tail');

    // What the buffer already held, timed and explained.
    await expect(page.getByTestId('tail-history-divider')).toBeVisible();
    const records = page.getByTestId('tail-record');
    await expect(records.first()).toContainText(/\d\d:\d\d:\d\d\.\d\d\d/);
    await expect(panel).toContainText('Bytes of memory the VM holds in all.');

    // The VM polls every second, so a live line soon sits above the divider.
    await expect(panel.locator('ol > li').first()).toHaveAttribute('data-testid', 'tail-record');

    await page.getByTestId('stop-tail').click();
    await expect(panel).toHaveCount(0);
    await expect(records).toHaveCount(0);
    await expect(button).toHaveAttribute('aria-pressed', 'false');
  });

  test('at phone width an open tail does not scroll sideways', async ({ page, live }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await live('/observability');

    // The process hub labels its signals, so its lines are the longest.
    await page.getByTestId('tail-processhub').click();
    await expect(page.getByTestId('tail-record').first()).toBeVisible();

    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    expect(overflow).toBeLessThanOrEqual(0);
  });
});
