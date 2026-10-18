import { test, expect } from './fixtures';

/**
 * The controller-health screen.
 *
 * The dev stack runs `local_only` with no remote tier, so that posture is the
 * one asserted; a controller reporting another one is a changed stack. A
 * breached RPO and a shutdown in progress cannot be arranged against a
 * controller that is meant to keep serving, and stopping it would stop every
 * session on the stack; all three are covered in
 * `test/flezha_ui_web/live/controller_live_test.exs`, as is a shipper retry,
 * which only a remote tier has.
 */
test.describe('Controller health', () => {
  test('states the posture, shutdown, boot, authz and shipper; stopping asks for the node name and cancelling stops nothing; memory is snapshotted only when asked', async ({
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

    await page.getByTestId('stop-controller-btn').click();
    const modal = page.getByTestId('stop-controller-modal');
    await expect(modal).toBeVisible();

    const confirm = page.getByTestId('stop-confirm');
    await expect(confirm).toBeDisabled();

    await page.getByTestId('stop-typed').fill('not-the-node');
    await expect(confirm).toBeDisabled();

    const label = await modal.locator('label').filter({ hasText: 'Type ' }).innerText();
    const node = label.replace(/^Type /, '').replace(/ to confirm$/, '').trim();
    await page.getByTestId('stop-typed').fill(node);
    await expect(confirm).toBeEnabled();

    // The drain timeout and force are asked for here, and sent only on confirm.
    await page.getByTestId('stop-timeout').fill('30');
    await page.getByTestId('stop-force').check();
    await expect(confirm).toBeEnabled();

    await page.getByTestId('stop-cancel').click();
    await expect(modal).toHaveCount(0);

    await page.getByTestId('stop-controller-btn').click();
    await expect(modal).toBeVisible();
    await page.getByTestId('stop-controller-close').click();
    await expect(modal).toHaveCount(0);
    await expect(page.getByTestId('shutdown-in-progress')).toHaveText('No');

    // Nothing on arrival: a process scan is too expensive for a refresh tick.
    await expect(page.getByTestId('memory-panel')).toBeVisible();
    await expect(page.getByTestId('memory-captured-at')).toHaveCount(0);

    await page.getByTestId('memory-snapshot-btn').click();

    // The answer is brought into view and announced, never left below the fold.
    const captured = page.getByTestId('memory-captured-at');
    await expect(captured).toBeInViewport();
    await expect(page.locator('.fui-toast').filter({ hasText: 'Memory snapshot taken.' })).toBeVisible();
    await expect(captured).toContainText('Captured at');
    await expect(page.getByTestId('memory-top-processes')).toBeVisible();
    // Each process reads with its queue and how it was started, named when it
    // is registered: a controller's busiest processes include named servers.
    const table = page.getByTestId('memory-top-processes');
    await expect(table.locator('th')).toContainText(['Process', 'Memory', 'Queue', 'Started as']);
    await expect(table.locator('tbody td[data-label="Process"]').filter({ hasNotText: '<0.' })).not.toHaveCount(0);
  });
});
