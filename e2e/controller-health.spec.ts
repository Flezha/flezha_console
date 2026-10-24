import { test, expect } from './fixtures';

/**
 * The controller-health screen.
 *
 * The dev stack runs `local_only` with no remote tier, so that posture is the
 * one asserted; a controller reporting another one is a changed stack. A
 * breached RPO and a shutdown in progress cannot be arranged against a
 * controller that is meant to keep serving; both are covered in
 * `test/flezha_console_web/live/controller_live_test.exs`, as is a shipper retry,
 * which only a remote tier has.
 */
test.describe('Controller health', () => {
  test('states the posture, shutdown, boot, authz and shipper; memory is snapshotted only when asked', async ({
    page,
    live,
  }) => {
    await live('/controller');

    // local_only ships nowhere, so it has no backend and nothing to breach.
    await expect(page.getByTestId('durability-backend')).toHaveText('None');
    await expect(
      page.getByTestId('durability-posture'),
      'the dev stack runs local_only; check docker-compose.dev.yml',
    ).toContainText('one copy, on the node that wrote it');
    await expect(page.getByTestId('durability-breaches')).toHaveText('0');
    await expect(page.getByTestId('durability-superseded')).toHaveText('0');

    // Informational, not an error: an alarm would carry the alert role.
    const notice = page.getByTestId('durability-local-only');
    await expect(notice).toContainText('exactly one copy');
    await expect(notice).not.toHaveAttribute('role', 'alert');

    await expect(page.getByTestId('shutdown-in-progress')).toHaveText('No');
    // Said in words, never the raw `nil` a not-shutting-down coordinator reports.
    await expect(page.getByTestId('shutdown-phase')).toHaveText('Not stopping');
    await expect(page.getByTestId('boot-default')).toContainText('Serving');
    await expect(page.getByTestId('authz-posture')).toContainText('Enforced');

    await expect(page.getByTestId('shipper-not-applicable')).toBeVisible();
    await expect(page.getByTestId('shipper-table')).toHaveCount(0);

    // Nothing on arrival: a process scan is too expensive for a refresh tick.
    await expect(page.getByTestId('memory-panel')).toBeVisible();
    await expect(page.getByTestId('memory-captured-at')).toHaveCount(0);

    await page.getByTestId('memory-snapshot-btn').click();

    // The answer is brought into view and announced, never left below the fold.
    const captured = page.getByTestId('memory-captured-at');
    await expect(captured).toBeInViewport();
    await expect(page.locator('.fcon-toast').filter({ hasText: 'Memory snapshot taken.' })).toBeVisible();
    await expect(captured).toContainText('Captured at');
    await expect(page.getByTestId('memory-top-processes')).toBeVisible();
    // Each process reads with its queue and how it was started, named when it
    // is registered: a controller's busiest processes include named servers.
    const table = page.getByTestId('memory-top-processes');
    await expect(table.locator('th')).toContainText(['Process', 'Memory', 'Queue', 'Started as']);
    await expect(table.locator('tbody td[data-label="Process"]').filter({ hasNotText: '<0.' })).not.toHaveCount(0);
  });
});
