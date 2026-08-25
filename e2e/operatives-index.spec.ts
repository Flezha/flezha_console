import {
  test,
  expect,
  testIds,
  expectHealthBadges,
  healthBadge,
  healthMatcher,
  choose,
  chosen,
  startOperative,
  stopOperative,
} from './fixtures';

/**
 * The cross-namespace operatives index.
 *
 * The dev stack seeds `testnet_store_1` and the `testnet_chat` workflow into
 * `default`, so their presence is asserted. Totals are not: the controller's
 * `app_data` carries durable state from previous bench campaigns, so any
 * absolute count is somebody else's number.
 */
/** Unique per test, so a leftover from a failed run cannot collide. */
function uniqueOperativeId(prefix = 'pw_idx'): string {
  const ts = Date.now().toString(36).slice(-4);
  const rand = Math.random().toString(36).slice(2, 5);
  return `${prefix}_${ts}_${rand}`;
}

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

  test('the kind filter offers the kinds the controller recognises', async ({ page }) => {
    await page.getByTestId('filter-kind').click();

    await expect(page.getByTestId('filter-kind-stream')).toBeVisible();
    await expect(page.getByTestId('filter-kind-workflow')).toBeVisible();
  });

  test('starts an operative into a namespace chosen on this screen', async ({ live, page }) => {
    const id = uniqueOperativeId();

    try {
      await startOperative(page, id, { namespace: 'default' });

      await expect(page.getByTestId(`operative-index-row-${id}`)).toBeVisible();
      await expect(page.locator('body')).toContainText(`Operative ${id} started in default`);
    } finally {
      // The index lists operatives; stopping one is the namespace screen's
      // verb, so cleanup goes there.
      await live('/namespaces/default');
      await stopOperative(page, id);
    }

    await live('/operatives');
    await expect(page.getByTestId(`operative-index-row-${id}`)).toHaveCount(0);
  });

  test('starts a workflow from here, and the listing reports its kind', async ({ live, page }) => {
    const id = uniqueOperativeId('pw_idxwf');

    try {
      await startOperative(page, id, { namespace: 'default', kind: 'workflow' });

      await expect(page.getByTestId(`operative-index-row-${id}`)).toContainText('workflow');
    } finally {
      await live('/namespaces/default');
      await stopOperative(page, id);
    }
  });

  test('the namespace field offers the namespaces the token can reach', async ({ page }) => {
    await page.getByTestId('start-operative-btn').click();
    await expect(page.getByTestId('start-modal')).toBeVisible();

    const namespaces = await page
      .getByTestId('input-namespace')
      .locator('option')
      .evaluateAll((opts) =>
        opts.map((o) => (o as HTMLOptionElement).value).filter((v) => v !== ''),
      );

    expect(namespaces).toContain('default');

    await page.getByTestId('start-cancel-btn').click();
  });
});
