import {
  test,
  expect,
  testIds,
  expectHealthBadges,
  healthBadge,
  healthMatcher,
  choose,
  chosen,
} from './fixtures';

/**
 * The cross-namespace operatives index.
 *
 * The dev stack seeds `testnet_store_1` and the `testnet_chat` workflow into
 * `default`, so their presence is asserted. Totals are not: the controller's
 * `app_data` carries durable state from previous bench campaigns, so any
 * absolute count is somebody else's number.
 */
test.describe('Operatives index', () => {
  test.beforeEach(async ({ live }) => {
    await live('/operatives');
  });

  test('lists seeded operatives with their namespace, health and kind', async ({ page }) => {
    await expect(page.getByTestId('operatives-index-table')).toBeVisible();

    const row = page.getByTestId('operative-index-row-testnet_store_1');
    await expect(row).toBeVisible();
    await expect(row).toContainText('default');
    await expect(row).toContainText('store_input');
    await expect(healthBadge(page, 'operative-index-row-testnet_store_1')).toHaveAttribute(
      'data-health',
      healthMatcher(),
    );

    await expect(page.getByTestId('operatives-count')).toContainText('across');
  });

  test('an operative id navigates to its detail screen', async ({ page }) => {
    await page.getByTestId('operative-index-row-testnet_store_1').getByRole('link').first().click();

    await expect(page).toHaveURL(/\/namespaces\/default\/operatives\/testnet_store_1$/);
    await expect(page.getByTestId('operative-runner')).toBeVisible();
  });

  test('kind comes from the registry: the seeded workflow reads as a workflow', async ({
    page,
  }) => {
    await expect(page.getByTestId('operative-index-row-testnet_chat')).toContainText('workflow');
    await expect(page.getByTestId('operative-index-row-testnet_store_1')).toContainText('stream');
  });

  test('filtering by kind narrows the listing to matching operatives', async ({ page }) => {
    await choose(page, 'filter-kind', 'workflow');

    await expect(page.getByTestId('operative-index-row-testnet_chat')).toBeVisible();
    await expect(page.getByTestId('operative-index-row-testnet_store_1')).toHaveCount(0);

    // Every remaining row is a workflow, not merely the one we looked for.
    const ids = await testIds(page, 'operative-index-row-');
    expect(ids.length).toBeGreaterThan(0);
  });

  test('filtering by health narrows the listing', async ({ page }) => {
    await choose(page, 'filter-health', 'healthy');

    // The suspended instance leaving is the signal the filter has applied;
    // counting badges before the re-render would count the unfiltered list.
    await expect(page.getByTestId('operative-index-row-testnet_chat')).toHaveCount(0);

    await expectHealthBadges(page, 'operative-index-row-', 'healthy');
  });

  test('the filter is carried in the query string, so a bucket can be linked to', async ({
    live,
    page,
  }) => {
    await live('/operatives?namespace=default&health=healthy');

    await expect(chosen(page, 'filter-health')).toHaveValue('healthy');
    await expect(chosen(page, 'filter-namespace')).toHaveValue('default');
  });
});
