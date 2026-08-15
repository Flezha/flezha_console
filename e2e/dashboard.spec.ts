import { test, expect } from './fixtures';

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

  test('the stat tiles carry concrete counts', async ({ page }) => {
    await expect(page.getByTestId('stat-namespaces')).toHaveText(/^\s*\d+\s*$/);
    await expect(page.getByTestId('stat-operatives')).toHaveText(/^\s*\d+\s*$/);
    await expect(page.getByTestId('stat-plugins')).toHaveText(/^\s*\d+\s*$/);
    await expect(page.getByTestId('stat-providers')).toContainText(/\d+ providers available/);
  });

  test('lists the runner fleet', async ({ page }) => {
    await expect(
      page.getByTestId('dashboard-runners-empty'),
      'at least one runner must be connected — check the runner service',
    ).toHaveCount(0);

    await expect(page.locator('[data-testid^="dashboard-runner-row-"]')).not.toHaveCount(0);
  });

  test('its counts agree with the namespace screen', async ({ page, live }) => {
    const namespaceCount = Number(await page.getByTestId('stat-namespaces').innerText());
    const operativeCount = Number(await page.getByTestId('stat-operatives').innerText());

    await live('/namespaces');

    const rows = page.locator('[data-testid^="namespace-row-"]');
    await expect(rows).toHaveCount(namespaceCount);

    const perNamespace = await page
      .locator('[data-testid^="namespace-operatives-"]')
      .evaluateAll((cells) => cells.map((c) => Number(c.textContent!.trim())));

    expect(perNamespace.reduce((a, b) => a + b, 0)).toBe(operativeCount);
  });

  test('links through to a namespace', async ({ page }) => {
    await page.getByTestId('dashboard-namespace-default').click();
    await expect(page).toHaveURL(/\/namespaces\/default$/);
    await expect(page.getByTestId('operatives-table')).toBeVisible();
  });
});
