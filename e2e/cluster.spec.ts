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
 * offered only when one namespace's runners sit on more than one node. Every
 * factory the screen offers comes from a connected runner, a drop takes the
 * runner from every session on the stack, and the dev stack's two controllers
 * each serve a namespace of their own with healthy runners, so these are
 * covered in `test/flezha_console_web/live/cluster_live_test.exs` and
 * `runner_drop_test.exs`. How many controllers and nodes there are is the
 * stack's to say, so they are read for their form.
 */
test.describe('Cluster and fleet', () => {
  test('the overview counts the dev stack and leads to its problems', async ({ page, live }) => {
    await live('/cluster');

    // How large the fleet is is the stack's to say, so each figure is read for
    // its form.
    for (const tile of ['sys-namespaces', 'sys-nodes', 'sys-runners', 'sys-relays', 'sys-problems']) {
      await expect(page.getByTestId(`${tile}-value`), tile).toHaveText(/\d/);
    }
    await expect(page.getByTestId('sys-nodes-condition')).toContainText('This console is connected to');
    await expect(page.getByTestId('sys-controller-value')).toHaveText(/\w/);

    await page.getByTestId('sys-problems').click();
    await expect(page).toHaveURL(/\/problems$/);
  });

  test('shows the nodes, hub placement, runners and factories, looks a factory up, cancels a runner drop, and explains hub recovery', async ({
    page,
    live,
  }) => {
    await live('/cluster');

    const nodes = page.getByTestId('cluster-nodes');
    await expect(nodes.locator('li')).not.toHaveCount(0);
    await expect(nodes.locator('li').filter({ hasText: 'Connected to this console' })).toHaveCount(1);
    await expect(nodes).toContainText('Connected to this console');

    // The hub cell must say something definite rather than render blank.
    await expect(page.getByTestId('hub-nodes-default')).toContainText('flezha@');

    // A connected runner registers the test factories; an empty factory list
    // would mean the handshake completed but registration did not. The filter
    // keeps the runners serving one, and the summary still counts them all.
    // How many runners, nodes and late runners there are is the stack's to
    // say, so the summary is read for its form.
    const runners = page.getByTestId('runners-default');
    const summary = page.getByTestId('runners-summary-default');
    await expect(summary).toContainText(/\d+ connected · \d+ nodes? · \d+ factories served\s*·\s*\d+ late/);
    await page.getByTestId('runner-filter-default').fill('store_input');
    await expect(runners.locator('tbody tr').first()).toContainText('store_input');
    await expect(page.locator('[data-testid^="node-count-"]').first()).toHaveText(/^\s*\d+\s*$/);

    // One runner serving the flow factory, named by its id from here on.
    const runnerId = (await runners.locator('tbody tr').first().getAttribute('data-testid'))!.replace('runner-', '');

    // Each runner says where it is held, since when, and when it was last heard from.
    await expect(page.getByTestId(`runner-node-of-${runnerId}`)).toContainText('flezha@');
    await expect(page.getByTestId(`runner-connected-${runnerId}`)).toContainText(/ago|now/);
    await expect(page.getByTestId(`runner-contact-${runnerId}`)).toContainText(/ago|now/);
    await expect(page.getByTestId(`runner-relays-${runnerId}`)).toHaveAttribute(
      'href',
      `/namespaces/default/relays?runner=${runnerId}`,
    );

    // A runner serving more than two factories shows two, and the rest on request.
    const more = runners.locator('[data-testid^="serves-more-"]').first();
    const moreId = (await more.getAttribute('data-testid'))!.replace('serves-more-', '');
    const rest = page.locator(`#serves-rest-default-${moreId}`);
    await expect(rest).toBeHidden();
    await more.click();
    await expect(rest).toBeVisible();
    await expect(more).toHaveAttribute('aria-expanded', 'true');

    // Whether a runner is late is the fleet's to say, so "Late only" is
    // asserted in ExUnit; the sort keeps every runner.
    await page.getByTestId('runner-filter-default').fill('');
    await choose(page, 'runner-sort-default', 'newest');
    await expect(page.getByTestId(`runner-${runnerId}`)).toBeVisible();

    // Each namespace offers its own factories; `second` serves one of the same name.
    const factory = page.locator('[data-testid="factory-store_input"][value="default/store_input"]');
    await expect(factory).toContainText('flow');
    await factory.click();
    const result = page.getByTestId('factory-runners');
    await expect(result).toContainText('store_input');
    await expect(result).toContainText('is served by');
    await page.getByRole('button', { name: 'Clear' }).click();
    await expect(result).toHaveCount(0);

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
