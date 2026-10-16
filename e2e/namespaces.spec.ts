import { test, expect } from './fixtures';

/**
 * The namespace index.
 *
 * The dev stack seeds the `default` namespace, so its presence is asserted
 * rather than discovered. How the counts are made, and the empty state, are
 * covered in `test/flezha_ui_web/live/namespace_live_test.exs`.
 */
test.describe('Namespaces', () => {
  test('lists the seeded namespace with its counts, and opens it', async ({ page, live }) => {
    await live('/namespaces');

    await expect(page.getByTestId('namespaces-table')).toBeVisible();
    await expect(page.getByTestId('namespace-row-default')).toBeVisible();
    await expect(page.getByTestId('namespace-relays-default')).toHaveText(/^\s*\d+ relays?\s*$/);
    // The dev stack runs one runner.
    await expect(page.getByTestId('namespace-runners-default')).toHaveText(/^\s*1 runner\s*$/);

    await page.getByTestId('namespace-view-default').click();

    await expect(page).toHaveURL(/\/namespaces\/default$/);
    await expect(page.getByTestId('home-namespace-tiles')).toBeVisible();
    await expect(page.getByTestId('start-relay-btn')).toBeVisible();
  });
});
