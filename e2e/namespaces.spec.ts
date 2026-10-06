import { test, expect } from './fixtures';

/**
 * The namespace index.
 *
 * The dev stack seeds the `default` namespace, so its presence is asserted
 * rather than discovered. The empty state is covered in
 * `test/flezha_ui_web/live/namespace_live_test.exs`.
 */
test.describe('Namespaces', () => {
  test.beforeEach(async ({ live }) => {
    await live('/namespaces');
  });

  test('lists the seeded namespace with its counts', async ({ page }) => {
    await expect(page.getByTestId('namespaces-table')).toBeVisible();
    await expect(page.getByTestId('namespace-row-default')).toBeVisible();

    await expect(page.getByTestId('namespace-relays-default')).toHaveText(/^\s*\d+\s*$/);
    await expect(page.getByTestId('namespace-runners-default')).toHaveText(/^\s*\d+\s*$/);
  });

  test('navigates into a namespace', async ({ page }) => {
    await page.getByTestId('namespace-view-default').click();

    await expect(page).toHaveURL(/\/namespaces\/default$/);
    await expect(page.getByTestId('relays-table')).toBeVisible();
    await expect(page.getByTestId('start-relay-btn')).toBeVisible();
  });

  test('the relay count matches the rows on the namespace page', async ({ page, live }) => {
    const claimed = Number(await page.getByTestId('namespace-relays-default').innerText());

    await live('/namespaces/default');

    await expect(page.locator('[data-testid^="relay-row-"]')).toHaveCount(claimed);
  });
});
