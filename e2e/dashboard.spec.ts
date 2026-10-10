import { test, expect, chosen, readFigure, testIds } from './fixtures';

/**
 * The dashboard.
 *
 * Its whole job is to report the controller's state at a glance, so the
 * assertions here are that the numbers are real and agree with the screens
 * they summarise — not merely that the tiles rendered.
 */
test.describe('Dashboard', () => {
  test.beforeEach(async ({ live }) => {
    await live('/');
  });

  test('reports the connected controller node and its transport', async ({ page }) => {
    await expect(
      page.getByTestId('node-disconnected'),
      'the UI must be connected to the controller — check the dev stack',
    ).toHaveCount(0);

    const node = page.getByTestId('node-connected');
    await expect(node).toContainText('flezha@');
    await expect(node).toContainText('Transport:');
  });

  test('the relay tile breaks its count down by health, and the parts add up', async ({ page }) => {
    const total = await readFigure(page.getByTestId('stat-relays'));
    const badges = page.getByTestId('stat-relay-health').getByTestId('health-badge');
    const counts = await badges.evaluateAll((els) =>
      els.map((el) => Number(el.querySelector('.flz-num')?.textContent?.trim() ?? 0)),
    );

    expect(counts.length).toBeGreaterThan(0);
    expect(counts.reduce((a, b) => a + b, 0)).toBe(total);
    // A healthy dev stack places every relay.
    await expect(page.getByTestId('stat-unplaced')).toHaveCount(0);
  });

  test('the plugin and provider tiles agree with the screens they count', async ({
    page,
    live,
  }) => {
    const plugins = await readFigure(page.getByTestId('stat-plugins'));
    const providers = await readFigure(page.getByTestId('stat-providers'));

    await live('/plugins');
    expect(await testIds(page, 'plugin-row-')).toHaveLength(plugins);

    await page.getByTestId('enable-plugin-btn').click();
    await expect(page.getByTestId('provider-grid')).toBeVisible();
    expect(await testIds(page, 'provider-btn-')).toHaveLength(providers);
    await page.getByTestId('attach-close-btn').click();
  });

  test('the namespace picker offers the running namespaces and summarises the chosen one', async ({
    page,
  }) => {
    // Switching between two namespaces needs a second running one, which the
    // dev stack does not have; `topology_live_test.exs` drives the switch.
    await page.getByTestId('topology-namespace').click();
    await expect(page.getByTestId('topology-namespace-default')).toBeVisible();
    await expect(page.getByTestId('topology-namespace-_system')).toHaveCount(0);
    await page.getByTestId('topology-namespace-default').click();

    await expect(chosen(page, 'topology-namespace')).toHaveValue('default');
    expect(await readFigure(page.getByTestId('summary-relays'))).toBe(
      await readFigure(page.getByTestId('stat-relays')),
    );
  });

  test('lists the runner fleet', async ({ page }) => {
    await expect(
      page.getByTestId('dashboard-runners-empty'),
      'at least one runner must be connected — check the runner service',
    ).toHaveCount(0);

    await expect(
      page.getByTestId('dashboard-runners').locator('[data-testid^="dashboard-runner-row-"]'),
    ).not.toHaveCount(0);
  });

  test('its counts agree with the namespace screen', async ({ page, live }) => {
    const namespaceCount = Number(await page.getByTestId('stat-namespaces').innerText());
    const relayCount = Number(await page.getByTestId('stat-relays').innerText());

    await live('/namespaces');

    const rows = page.locator('[data-testid^="namespace-row-"]');
    await expect(rows).toHaveCount(namespaceCount);

    const perNamespace = await page
      .locator('[data-testid^="namespace-relays-"]')
      .evaluateAll((cells) => cells.map((c) => Number(c.textContent!.trim())));

    expect(perNamespace.reduce((a, b) => a + b, 0)).toBe(relayCount);
  });

  test('links through to a namespace', async ({ page }) => {
    await page
      .getByTestId('dashboard-namespaces')
      .getByTestId('dashboard-namespace-default')
      .click();
    await expect(page).toHaveURL(/\/namespaces\/default$/);
    await expect(page.getByTestId('relays-table')).toBeVisible();
  });
});
