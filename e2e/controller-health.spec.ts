import { test, expect } from './fixtures';

/**
 * The controller-health screen.
 *
 * The dev stack runs `local_only` with no remote tier, so that posture is the
 * one to assert. A breached RPO and a shutdown in progress cannot be arranged
 * against a controller that is meant to keep serving; both are covered in
 * `test/flezha_ui_web/live/controller_live_test.exs`.
 */
test.describe('Controller health', () => {
  test.beforeEach(async ({ live }) => {
    await live('/controller');
  });

  test('shows the durability backend, posture and counts', async ({ page }) => {
    await expect(page.getByTestId('durability-panel')).toBeVisible();
    await expect(page.getByTestId('durability-backend')).not.toBeEmpty();
    await expect(page.getByTestId('durability-posture')).toContainText(
      /remote_tier|local_only/,
    );
    await expect(page.getByTestId('durability-breaches')).toHaveText(/^\s*\d+\s*$/);
    await expect(page.getByTestId('durability-superseded')).toHaveText(/^\s*\d+\s*$/);
  });

  test('local_only is stated as a posture rather than raised as an alarm', async ({ page }) => {
    const posture = await page.getByTestId('durability-posture').innerText();
    test.skip(!posture.includes('local_only'), 'controller is running a remote tier');

    const notice = page.getByTestId('durability-local-only');
    await expect(notice).toBeVisible();
    await expect(notice).toContainText('exactly one copy');
    // Informational, not an error: an alarm would carry the alert role.
    await expect(notice).not.toHaveAttribute('role', 'alert');
  });

  test('shutdown and boot state render', async ({ page }) => {
    await expect(page.getByTestId('shutdown-in-progress')).toHaveText('no');
    // Never the raw `nil` a not-shutting-down coordinator reports.
    await expect(page.getByTestId('shutdown-phase')).toHaveText(/\S/);
    await expect(page.getByTestId('shutdown-phase')).not.toHaveText('nil');

    await expect(page.getByTestId('boot-default')).toContainText('normal');
  });

  test('the memory snapshot is taken only when asked, and labelled when taken', async ({
    page,
  }) => {
    // Nothing on arrival: a process scan is too expensive for a refresh tick.
    await expect(page.getByTestId('memory-captured-at')).toHaveCount(0);

    await page.getByTestId('memory-snapshot-btn').click();

    const captured = page.getByTestId('memory-captured-at');
    await expect(captured).toBeVisible();
    await expect(captured).toContainText('Captured at');
    await expect(page.getByTestId('memory-top-processes')).toBeVisible();
  });
});
