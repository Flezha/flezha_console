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
    await expect(runners.locator('li')).not.toHaveCount(0);

    // A connected runner registers the test factories; an empty factory list
    // would mean the handshake completed but registration did not.
    await expect(runners.locator('li').first()).toContainText('store_input');
  });

  test('looks up which runners serve a factory, and clears the selection', async ({ page }) => {
    await page.getByTestId('factory-store_input').click();

    const result = page.getByTestId('factory-runners');
    await expect(result).toContainText('store_input');
    await expect(result).toContainText('is served by');

    await page.getByRole('button', { name: 'Clear' }).click();
    await expect(result).toHaveCount(0);
  });
});
