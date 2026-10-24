import { test, expect } from './fixtures';
import type { Locator } from '@playwright/test';

/**
 * Observability sources, what they said recently, and a tail of one, against
 * the real controller.
 *
 * Toggling a source is controller-wide and asks for no confirmation, so it is
 * covered in `test/flezha_console_web/live/observability_live_test.exs` alone, as is
 * how the tail renders what it receives. A tail's records are this page's
 * own, so its first record is read without regard to other workers.
 */

/** The computed font size and colour of `locator`, as one comparable string. */
async function look(locator: Locator): Promise<string> {
  return locator.evaluate((el) => {
    const style = getComputedStyle(el);
    return `${style.fontSize} ${style.color}`;
  });
}

test.describe('Observability', () => {
  test('every source is headed by its plain title and says what it said recently; none that cannot speak is listed', async ({
    page,
    live,
  }) => {
    await live('/observability');

    await expect(page.getByTestId('sources-panel')).toBeVisible();
    await expect(page.getByTestId('sinks-line')).toContainText('live tails');
    await expect(page.getByTestId('source-title-beam_vm')).toHaveText('Controller memory and load');
    await expect(page.getByTestId('source-beam_vm')).toContainText('beam_vm');
    await expect(page.getByTestId('source-description-beam_vm')).toContainText('Erlang VM');
    // The VM reports on every poll, so it always has something recent to say, by label.
    await expect(page.getByTestId('source-activity-beam_vm')).toContainText(/\d\S* [a-z].* · last \S+ ago/);
    await expect(page.getByTestId('source-group-machine')).toBeVisible();

    // A source that can report failures says whether it did.
    await expect(page.getByTestId('source-activity-flezha_runner')).toContainText(
      /No failures in the last|failures? in the last/,
    );

    for (const gone of ['flezha_reconcile', 'flezha_leadership', 'flezha_bounded_mailbox']) {
      await expect(page.getByTestId(`source-${gone}`)).toHaveCount(0);
    }
  });

  test('a tail opens with recent history as sentences, adds live signals above it, and stops', async ({
    page,
    live,
  }) => {
    await live('/observability');

    const button = page.getByTestId('tail-beam_vm');
    await button.click();

    // The tail opens beside the listing at once, wherever the source sat.
    const panel = page.getByTestId('tail-panel');
    await expect(panel).toBeInViewport();
    await expect(panel.locator('.fcon-drawer-title')).toHaveText('Controller memory and load');
    await expect(page.getByTestId('tail-panel-subtitle')).toHaveText('beam_vm');
    await expect(button).toHaveAttribute('aria-pressed', 'true');
    await expect(button).toContainText('Stop tail');

    // What the buffer already held, timed and told as sentences.
    await expect(page.getByTestId('tail-history-divider')).toBeVisible();
    const records = page.getByTestId('tail-record');
    await expect(records.first()).toContainText(/\d\d:\d\d:\d\d\.\d\d\d/);
    await expect(page.getByTestId('tail-count')).toContainText(/Live · \d+ signals · newest first/);

    // The VM polls every second, so a live line soon sits above the divider.
    await expect(panel.locator('ol > li').first()).toHaveAttribute('data-testid', 'tail-record');

    // A line's fields are one click away, and stay open as signals arrive.
    const first = panel.locator('[data-testid="tail-record"]', { hasText: 'The VM holds' }).first();
    // Pinned by its id: new lines arrive above it while the test reads it.
    const id = await first.getByTestId('tail-details').getAttribute('id');
    const details = page.locator(`#${id}`);
    const line = page.getByTestId('tail-record').filter({ has: details });
    await expect(line.getByTestId('tail-sentence')).toHaveText(/The VM holds \S+ bytes in all/);
    await expect(details.locator('.fcon-tech-name')).toBeHidden();
    // Dispatched, not clicked: each VM poll moves the line down, and a pointer
    // click waits for it to stand still.
    await details.locator('summary').dispatchEvent('click');
    await expect(details.locator('.fcon-tech-name')).toContainText(/value \S+/);
    const count = page.getByTestId('tail-count');
    const before = await count.textContent();
    await expect(count).not.toHaveText(before ?? '');
    await expect(details).toHaveAttribute('open', '');

    await page.getByTestId('stop-tail').click();
    await expect(panel).toHaveCount(0);
    await expect(records).toHaveCount(0);
    await expect(button).toHaveAttribute('aria-pressed', 'false');
  });

  test('a waiting tail sets the lead, status, empty state and catalogue apart', async ({ page, live }) => {
    await live('/observability');

    // Corrections are refused rarely, so this tail waits for its first signal.
    await page.getByTestId('tail-flezha_correction').click();
    const panel = page.getByTestId('tail-panel');
    await expect(page.getByTestId('tail-count')).toHaveText('Waiting for the first signal');

    const failures = page.getByTestId('tail-meanings-failure');
    await expect(failures).toContainText('When something goes wrong');
    await expect(failures).toContainText('Correction refused');
    await expect(failures).toContainText('⚠ Failure');
    await expect(failures.locator('.fcon-tech-name')).toHaveText('refused');

    const looks = [
      await look(page.getByTestId('tail-lead')),
      await look(page.getByTestId('tail-count')),
      await look(panel.locator('.fcon-empty-text')),
      await look(failures.locator('.fcon-hint').first()),
    ];
    expect(new Set(looks).size).toBe(looks.length);
  });

  test('the list of what a source can say stays open while signals arrive', async ({ page, live }) => {
    await live('/observability');
    await page.getByTestId('tail-beam_vm').click();

    const fold = page.getByTestId('tail-meanings-fold');
    await fold.locator('summary').click();
    await expect(fold).toHaveAttribute('open', '');
    await expect(fold).toContainText('Memory in use');

    // The VM reports every second; wait for the count to move past what it was.
    const count = page.getByTestId('tail-count');
    const before = await count.textContent();
    await expect(count).not.toHaveText(before ?? '');
    await expect(fold).toHaveAttribute('open', '');
  });

  test('at phone width an open tail does not scroll sideways', async ({ page, live }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await live('/observability');

    // The process hub labels its signals, so its lines are the longest.
    await page.getByTestId('tail-processhub').click();
    await expect(page.getByTestId('tail-record').first()).toBeVisible();
    await page.getByTestId('tail-details').first().locator('summary').click();

    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    expect(overflow).toBeLessThanOrEqual(0);
  });
});
