import { test, expect, menuAction } from './fixtures';

/**
 * The cluster and fleet screen.
 *
 * Requires a running controller with at least one connected runner — the
 * dev compose runs the Rust runner as its own service, so an empty fleet is a
 * broken stack rather than a state to tolerate.
 *
 * Not covered here: the "no runner serves this factory" state. Every factory
 * the screen offers comes from a connected runner, so producing it would mean
 * stopping the runner mid-suite. It is covered in
 * `test/flezha_ui_web/live/cluster_live_test.exs` instead.
 */
test.describe('Cluster and fleet', () => {
  test.beforeEach(async ({ live }) => {
    await live('/cluster');
  });

  test('lists cluster nodes and marks the one this UI is connected to', async ({ page }) => {
    const nodes = page.getByTestId('cluster-nodes');
    await expect(nodes).toBeVisible();
    await expect(nodes.locator('li')).not.toHaveCount(0);
    await expect(nodes).toContainText('Connected to this console');
  });

  test('shows hub placement for each running namespace', async ({ page }) => {
    await expect(page.getByTestId('cluster-namespace-default')).toBeVisible();

    // The hub cell must say something definite rather than render blank.
    await expect(page.getByTestId('hub-nodes-default')).toContainText('flezha@');
  });

  test('lists the runners serving a namespace with their factories', async ({ page }) => {
    const runners = page.getByTestId('runners-default');
    await expect(runners).toBeVisible();
    await expect(runners.locator('tbody tr')).not.toHaveCount(0);

    // A connected runner registers the test factories; an empty factory list
    // would mean the handshake completed but registration did not.
    await expect(runners.locator('tbody tr').first()).toContainText('store_input');
  });

  test("each factory states its run, as its runners announce it", async ({ page }) => {
    await expect(page.getByTestId('factory-store_input')).toContainText('flow');
  });

  test('looks up which runners serve a factory, and clears the selection', async ({ page }) => {
    await page.getByTestId('factory-store_input').click();

    const result = page.getByTestId('factory-runners');
    await expect(result).toContainText('store_input');
    await expect(result).toContainText('is served by');

    await page.getByRole('button', { name: 'Clear' }).click();
    await expect(result).toHaveCount(0);
  });

  test('per-node counts break down by health, with hub recovery', async ({ page }) => {
    await expect(page.getByTestId('node-rollup-default')).toBeVisible();

    const counts = page.locator('[data-testid^="node-count-"]');
    await expect(counts.first()).toHaveText(/^\s*\d+\s*$/);

    // Recovery is either a state or an honest "unavailable" — never a guess.
    const recovery = page.locator(
      '[data-testid^="recovery-"], [data-testid^="recovery-unavailable-"]',
    );
    await expect(recovery.first()).toBeVisible();
  });

  test('the runner principal is the one the controller mints', async ({ page }) => {
    const principal = page.getByTestId('runner-principal-default');

    if (await principal.count()) {
      await expect(principal).toContainText('runner@default');
    }
  });

  test('hub recovery is explained behind a ?, with no button that does nothing', async ({
    page,
  }) => {
    await expect(page.getByTestId('open-recovery-default')).toHaveCount(0);
    // A serving hub raises no notice.
    await expect(page.locator('[data-testid^="hub-not-serving-"]')).toHaveCount(0);

    await page.getByTestId('help-rollup-default').click();
    await expect(page.locator('#help-rollup-default [role="dialog"]')).toContainText(
      'Recovery runs by itself',
    );
  });

  test('dropping a runner refuses its process until readmitted', async ({ page }) => {
    test.setTimeout(120_000);
    const runners = page.getByTestId('runners-default');
    const row = runners.locator('tbody tr').first();
    const runnerId = (await row.getAttribute('data-testid'))!.replace('runner-', '');

    // Cancelling asks the controller nothing.
    await menuAction(page, `runner-menu-${runnerId}`, `drop-runner-${runnerId}`);
    await expect(page.getByTestId('drop-runner-modal')).toContainText('refuses this same');
    await page.getByTestId('drop-runner-cancel').click();
    await expect(page.getByTestId(`runner-${runnerId}`)).toBeVisible();

    await menuAction(page, `runner-menu-${runnerId}`, `drop-runner-${runnerId}`);
    await page.getByTestId('drop-runner-confirm').click();

    const marks = page.getByTestId('runner-marks-default');
    await expect(marks).toBeVisible();
    await expect(marks).toContainText('Dropped');
    await expect(page.getByTestId(`runner-${runnerId}`)).toHaveCount(0);

    // The same process keeps retrying and keeps being refused.
    await page.waitForTimeout(5_000);
    await expect(runners.locator('tbody tr')).toHaveCount(0);

    const mark = (await marks.locator('[data-testid^="runner-mark-"]').first().getAttribute('data-testid'))!;
    const stableId = mark.replace('runner-mark-', '');
    const readmit = () => menuAction(page, `mark-menu-${stableId}`, `readmit-runner-${stableId}`);
    await readmit();
    await expect(page.getByTestId('readmit-runner-modal')).toBeVisible();
    await page.getByTestId('readmit-runner-cancel').click();
    await expect(page.getByTestId('readmit-runner-modal')).toHaveCount(0);
    await expect(marks).toContainText('Dropped');

    await readmit();
    await page.getByTestId('readmit-runner-confirm').click();
    await expect(marks).toHaveCount(0);

    // Readmitted, the same process is admitted on its next retry.
    await expect(runners.locator('tbody tr')).not.toHaveCount(0, { timeout: 90_000 });
  });
});
