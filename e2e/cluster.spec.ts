import { test, expect, menuAction } from './fixtures';

/**
 * The cluster and fleet screen.
 *
 * Requires a running controller with at least one connected runner — the
 * dev compose runs the Rust runner as its own service, so an empty fleet is a
 * broken stack rather than a state to tolerate.
 *
 * Not covered here: the "no runner serves this factory" state, and a runner
 * actually dropped and readmitted. Every factory the screen offers comes from
 * a connected runner, and a drop takes the runner from every session on the
 * stack, so both are covered in `test/flezha_ui_web/live/cluster_live_test.exs`
 * and `runner_drop_test.exs` instead.
 */
test.describe('Cluster and fleet', () => {
  test('shows the nodes, hub placement, runners and factories, looks a factory up, cancels a runner drop, and explains hub recovery', async ({
    page,
    live,
  }) => {
    await live('/cluster');

    const nodes = page.getByTestId('cluster-nodes');
    await expect(nodes.locator('li')).not.toHaveCount(0);
    await expect(nodes).toContainText('Connected to this console');

    // The hub cell must say something definite rather than render blank.
    await expect(page.getByTestId('hub-nodes-default')).toContainText('flezha@');

    // A connected runner registers the test factories; an empty factory list
    // would mean the handshake completed but registration did not.
    const runners = page.getByTestId('runners-default');
    await expect(runners.locator('tbody tr').first()).toContainText('store_input');
    await expect(page.locator('[data-testid^="node-count-"]').first()).toHaveText(/^\s*\d+\s*$/);

    await expect(page.getByTestId('factory-store_input')).toContainText('flow');
    await page.getByTestId('factory-store_input').click();
    const result = page.getByTestId('factory-runners');
    await expect(result).toContainText('store_input');
    await expect(result).toContainText('is served by');
    await page.getByRole('button', { name: 'Clear' }).click();
    await expect(result).toHaveCount(0);

    const row = page.getByTestId('runners-default').locator('tbody tr').first();
    const runnerId = (await row.getAttribute('data-testid'))!.replace('runner-', '');

    await menuAction(page, `runner-menu-${runnerId}`, `drop-runner-${runnerId}`);
    await expect(page.getByTestId('drop-runner-modal')).toContainText('refuses this same');
    await page.getByTestId('drop-runner-cancel').click();
    await expect(page.getByTestId('drop-runner-modal')).toHaveCount(0);
    await expect(page.getByTestId(`runner-${runnerId}`)).toBeVisible();

    await expect(page.getByTestId('open-recovery-default')).toHaveCount(0);
    // A serving hub raises no notice.
    await expect(page.locator('[data-testid^="hub-not-serving-"]')).toHaveCount(0);

    await page.getByTestId('help-rollup-default').click();
    await expect(page.locator('#help-rollup-default [role="dialog"]')).toContainText(
      'Recovery runs by itself',
    );
  });
});
