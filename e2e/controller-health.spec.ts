import { test, expect } from './fixtures';

/**
 * The controller-health screen.
 *
 * The dev stack runs `local_only` with no remote tier, so that posture is the
 * one asserted; a controller reporting another one is a changed stack. A breached RPO and a shutdown in progress cannot be arranged
 * against a controller that is meant to keep serving; both are covered in
 * `test/flezha_ui_web/live/controller_live_test.exs`.
 */
test.describe('Controller health', () => {
  test.beforeEach(async ({ live }) => {
    await live('/controller');
  });

  test('shows the durability backend, posture and counts', async ({ page }) => {
    await expect(page.getByTestId('durability-panel')).toBeVisible();
    // local_only ships nowhere, so it has no backend and nothing to breach.
    await expect(page.getByTestId('durability-backend')).toHaveText('none');
    await expect(
      page.getByTestId('durability-posture'),
      'the dev stack runs local_only; check docker-compose.dev.yml',
    ).toContainText('local_only');
    await expect(page.getByTestId('durability-breaches')).toHaveText('0');
    await expect(page.getByTestId('durability-superseded')).toHaveText('0');
  });

  test('local_only is stated as a posture rather than raised as an alarm', async ({ page }) => {
    const notice = page.getByTestId('durability-local-only');
    await expect(notice).toBeVisible();
    await expect(notice).toContainText('exactly one copy');
    // Informational, not an error: an alarm would carry the alert role.
    await expect(notice).not.toHaveAttribute('role', 'alert');
  });

  test('shutdown, boot and authz state render', async ({ page }) => {
    await expect(page.getByTestId('shutdown-panel')).toBeVisible();
    await expect(page.getByTestId('shutdown-in-progress')).toHaveText('no');
    // Said in words, never the raw `nil` a not-shutting-down coordinator reports.
    await expect(page.getByTestId('shutdown-phase')).toHaveText('none');

    await expect(page.getByTestId('boot-default')).toContainText('normal');

    await expect(page.getByTestId('authz-panel')).toBeVisible();
    await expect(page.getByTestId('authz-posture')).toContainText('Posture: :enforced');
  });

  test('the memory snapshot is taken only when asked, and labelled when taken', async ({
    page,
  }) => {
    // Nothing on arrival: a process scan is too expensive for a refresh tick.
    await expect(page.getByTestId('memory-panel')).toBeVisible();
    await expect(page.getByTestId('memory-captured-at')).toHaveCount(0);

    await page.getByTestId('memory-snapshot-btn').click();

    const captured = page.getByTestId('memory-captured-at');
    await expect(captured).toBeVisible();
    await expect(captured).toContainText('Captured at');
    await expect(page.getByTestId('memory-top-processes')).toBeVisible();
  });

  test('the shipper is stated as not applicable on a local-only controller', async ({ page }) => {
    await expect(page.getByTestId('shipper-not-applicable')).toBeVisible();
    await expect(page.getByTestId('shipper-table')).toHaveCount(0);
  });

  test('stopping asks for the node name, and cancelling stops nothing', async ({ page }) => {
    await page.getByTestId('stop-controller-btn').click();
    const modal = page.getByTestId('stop-controller-modal');
    await expect(modal).toBeVisible();

    const confirm = page.getByTestId('stop-confirm');
    await expect(confirm).toBeDisabled();

    await page.getByTestId('stop-typed').fill('not-the-node');
    await expect(confirm).toBeDisabled();

    const label = await modal.locator('label[for], .flz-field-label').filter({ hasText: 'Type ' }).innerText();
    const node = label.replace(/^Type /, '').replace(/ to confirm$/, '').trim();
    await page.getByTestId('stop-typed').fill(node);
    await expect(confirm).toBeEnabled();

    // The drain timeout and force are asked for here, and sent only on confirm.
    await page.getByTestId('stop-timeout').fill('30');
    await page.getByTestId('stop-force').check();
    await expect(confirm).toBeEnabled();

    await page.getByTestId('stop-cancel').click();
    await expect(modal).toHaveCount(0);
    await expect(page.getByTestId('shutdown-in-progress')).toHaveText('no');
  });

  test('the stop dialog also closes from its close control, stopping nothing', async ({ page }) => {
    await page.getByTestId('stop-controller-btn').click();
    await expect(page.getByTestId('stop-controller-modal')).toBeVisible();

    await page.getByTestId('stop-controller-close').click();
    await expect(page.getByTestId('stop-controller-modal')).toHaveCount(0);
    await expect(page.getByTestId('shutdown-in-progress')).toHaveText('no');
    await expect(page.getByTestId('shutdown-phase')).not.toHaveText(/drain|finalise/);
  });
});

