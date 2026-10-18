import { test, expect, menuAction, choose } from './fixtures';

/**
 * The cluster and fleet screen.
 *
 * Requires a running controller with at least one connected runner — the
 * dev compose runs the Rust runner as its own service, so an empty fleet is a
 * broken stack rather than a state to tolerate.
 *
 * Not covered here: the "no runner serves this factory" state, a runner
 * actually dropped and readmitted, a late runner, and the node choice, which is
 * offered only when runners sit on more than one node. Every factory the screen
 * offers comes from a connected runner, a drop takes the runner from every
 * session on the stack, and the dev stack runs one controller node with
 * healthy runners, so these are covered in
 * `test/flezha_ui_web/live/cluster_live_test.exs` and `runner_drop_test.exs`.
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
    // would mean the handshake completed but registration did not. The filter
    // keeps the runners serving one, and the summary still counts them all.
    const runners = page.getByTestId('runners-default');
    const summary = page.getByTestId('runners-summary-default');
    await expect(summary).toContainText(/\d+ connected · 1 node · \d+ factories served ·\s*0 late/);
    await page.getByTestId('runner-filter-default').fill('store_input');
    await expect(runners.locator('tbody tr').first()).toContainText('store_input');
    await expect(page.locator('[data-testid^="node-count-"]').first()).toHaveText(/^\s*\d+\s*$/);

    // Each runner says where it is held, since when, and when it was last heard from.
    const first = runners.locator('tbody tr').first();
    const firstId = (await first.getAttribute('data-testid'))!.replace('runner-', '');
    await expect(page.getByTestId(`runner-node-of-${firstId}`)).toContainText('flezha@');
    await expect(page.getByTestId(`runner-connected-${firstId}`)).toContainText(/ago|now/);
    await expect(page.getByTestId(`runner-contact-${firstId}`)).toContainText(/ago|now/);
    await expect(page.getByTestId(`runner-relays-${firstId}`)).toHaveAttribute(
      'href',
      `/namespaces/default/relays?runner=${firstId}`,
    );

    // A runner serving more than two factories shows two, and the rest on request.
    const more = page.locator('[data-testid^="serves-more-"]').first();
    const moreId = (await more.getAttribute('data-testid'))!.replace('serves-more-', '');
    const rest = page.locator(`#serves-rest-default-${moreId}`);
    await expect(rest).toBeHidden();
    await more.click();
    await expect(rest).toBeVisible();
    await expect(more).toHaveAttribute('aria-expanded', 'true');

    // No runner is late on a healthy stack, so "Late only" lists none; the
    // sort keeps every runner.
    await page.getByTestId('runner-filter-default').fill('');
    await page.getByTestId('runner-late-default').check();
    await expect(page.getByTestId('runners-none-match-default')).toBeVisible();
    await page.getByTestId('runner-late-default').uncheck();
    await choose(page, 'runner-sort-default', 'newest');
    await expect(runners.locator('tbody tr')).not.toHaveCount(0);

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
    await expect(page.getByTestId('drop-runner-modal')).toContainText(/on flezha@.*connected/);
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
