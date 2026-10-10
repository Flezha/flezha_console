import { test, expect } from './fixtures';

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
    await expect(nodes).toContainText('connected to this UI');
  });

  test('shows hub placement for each running namespace', async ({ page }) => {
    await expect(page.getByTestId('cluster-namespace-default')).toBeVisible();

    // The hub cell must say something definite rather than render blank.
    await expect(page.getByTestId('hub-nodes-default')).not.toBeEmpty();
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

  test("a namespace's recovery opens per hub and per node, and closes", async ({ page }) => {
    await page.getByTestId('open-recovery-default').click();

    const modal = page.getByTestId('recovery-modal');
    await expect(modal).toBeVisible();
    await expect(page.getByTestId('recovery-hub-id')).toHaveText(/\S/);
    await expect(page.getByTestId('recovery-local')).toContainText('serving');
    await expect(
      page.getByTestId('recovery-per-node').locator('[data-testid^="recovery-node-"]'),
    ).not.toHaveCount(0);

    await page.getByTestId('recovery-close').click();
    await expect(modal).toHaveCount(0);
  });

  test('dropping a runner refuses its process until readmitted', async ({ page }) => {
    test.setTimeout(120_000);
    const runners = page.getByTestId('runners-default');
    const row = runners.locator('tbody tr').first();
    const runnerId = (await row.getAttribute('data-testid'))!.replace('runner-', '');

    // Cancelling asks the controller nothing.
    await page.getByTestId(`drop-runner-${runnerId}`).click();
    await expect(page.getByTestId('drop-runner-modal')).toContainText('refuses this same');
    await page.getByTestId('drop-runner-cancel').click();
    await expect(page.getByTestId(`runner-${runnerId}`)).toBeVisible();

    await page.getByTestId(`drop-runner-${runnerId}`).click();
    await page.getByTestId('drop-runner-confirm').click();

    const marks = page.getByTestId('runner-marks-default');
    await expect(marks).toBeVisible();
    await expect(marks).toContainText('dropped');
    await expect(page.getByTestId(`runner-${runnerId}`)).toHaveCount(0);

    // The same process keeps retrying and keeps being refused.
    await page.waitForTimeout(5_000);
    await expect(runners.locator('tbody tr')).toHaveCount(0);

    const readmit = marks.locator('[data-testid^="readmit-runner-"]').first();
    await readmit.click();
    await page.getByTestId('readmit-runner-confirm').click();
    await expect(marks).toHaveCount(0);

    // Readmitted, the same process is admitted on its next retry.
    await expect(runners.locator('tbody tr')).not.toHaveCount(0, { timeout: 90_000 });
  });
});
