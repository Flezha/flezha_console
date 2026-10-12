import {
  menuAction,
  test,
  expect,
  expectHealthBadges,
  healthBadge,
  healthMatcher,
  choose,
  chosen,
  startRelay,
  stopRelay,
  withStepsRelay,
  HEALTH_VERDICTS,
  uniqueId,
  visitLive,
  openPage,
} from './fixtures';

/**
 * The cross-namespace relays index.
 *
 * The dev stack seeds the flow relay `testnet_store_1` into `default`, so
 * its presence is asserted; a test that needs a steps relay starts its own. Totals are not: the
 * controller's `app_data` may carry durable state from earlier campaigns, so
 * any absolute count is somebody else's number.
 */
test.describe('Relays index', () => {
  test.beforeEach(async ({ live }) => {
    await live('/relays');
  });

  test('lists seeded relays with their namespace, health and run', async ({ page }) => {
    await expect(page.getByTestId('relays-index-table')).toBeVisible();

    const row = page.getByTestId('relay-index-row-testnet_store_1');
    await expect(row).toBeVisible();
    await expect(row).toContainText('default');
    await expect(row).toContainText('store_input');
    await expect(healthBadge(page, 'relay-index-row-testnet_store_1')).toHaveAttribute(
      'data-health',
      healthMatcher(),
    );

    await expect(page.getByTestId('relays-count')).toContainText('across');
  });

  test('a row opens its relay in the inspector, and its menu opens the relay', async ({ page }) => {
    await page.getByTestId('relay-index-row-testnet_store_1').click();
    await expect(page.getByTestId('inspector-relay')).toBeVisible();
    await page.getByTestId('inspector-close').click();

    await menuAction(page, 'relay-menu-testnet_store_1', 'view-relay-testnet_store_1');

    await expect(page).toHaveURL(/\/namespaces\/default\/relays\/testnet_store_1$/);
    await expect(page.getByTestId('relay-runner')).toBeVisible();
  });

  test("a relay's name and its Open button go straight to its page", async ({ page, live }) => {
    await page.getByTestId('relay-link-testnet_store_1').click();
    await expect(page).toHaveURL(/\/namespaces\/default\/relays\/testnet_store_1$/);
    await expect(page.getByTestId('inspector-relay')).toHaveCount(0);
    await expect(page.getByTestId('topology-graph')).toBeVisible();

    await live('/relays');
    await page.getByTestId('open-relay-testnet_store_1').click();
    await expect(page).toHaveURL(/\/namespaces\/default\/relays\/testnet_store_1$/);
  });

  test('run comes from the factory: a steps relay reads as steps', async ({ page, live }) => {
    await withStepsRelay(page, async (id) => {
      await live('/relays');
      await expect(page.getByTestId(`relay-index-row-${id}`)).toContainText('steps');
      await expect(page.getByTestId('relay-index-row-testnet_store_1')).toContainText('flow');
    });
  });

  test('filtering by run narrows the listing to matching relays', async ({ page, live }) => {
    await withStepsRelay(page, async (id) => {
      await live('/relays');
      await choose(page, 'filter-run', 'steps');

      await expect(page.getByTestId(`relay-index-row-${id}`)).toBeVisible();
      await expect(page.getByTestId('relay-index-row-testnet_store_1')).toHaveCount(0);
    });
  });

  test('filtering by health narrows the listing', async ({ page }) => {
    await choose(page, 'filter-health', 'healthy');

    // The query string carrying the filter is the signal it has applied, so
    // badges are not counted from the unfiltered list.
    await expect(page).toHaveURL(/health=healthy/);
    await expectHealthBadges(page, 'relay-index-row-', 'healthy');
  });

  test('filters combine, and a combination nothing matches says so', async ({ page }) => {
    await choose(page, 'filter-namespace', 'default');
    await expect(page).toHaveURL(/namespace=default/);
    await expect(page.getByTestId('relay-index-row-testnet_store_1')).toBeVisible();

    // No seeded flow relay is parked, so these two together match nothing.
    await choose(page, 'filter-run', 'flow');
    await choose(page, 'filter-health', 'parked');
    await expect(page).toHaveURL(/health=parked/);
    await expect(page.getByTestId('relays-empty')).toContainText(
      'No running relay matches these filters.',
    );
    await expect(page.locator('[data-testid^="relay-index-row-"]')).toHaveCount(0);
  });

  test('a relay started elsewhere appears here as its lifecycle entry arrives', async ({
    page,
  }) => {
    const id = uniqueId('pw_live');
    const other = await openPage(page, '/namespaces/default');

    try {
      await startRelay(other, id);

      await expect(
        page.getByTestId('lifecycle-feed').locator('li').filter({ hasText: id }),
      ).toHaveCount(1, {
        timeout: 15_000,
      });
      await expect(page.getByTestId(`relay-index-row-${id}`)).toBeVisible();
    } finally {
      await visitLive(other, '/namespaces/default');
      await stopRelay(other, id);
      await other.close();
    }
  });

  test('the health filter offers every verdict, recovering and parked included', async ({
    page,
  }) => {
    await page.getByTestId('filter-health').click();

    for (const verdict of HEALTH_VERDICTS) {
      await expect(page.getByTestId(`filter-health-${verdict}`)).toBeVisible();
    }
  });

  test('the filter is carried in the query string, so a bucket can be linked to', async ({
    live,
    page,
  }) => {
    await live('/relays?namespace=default&health=healthy&run=flow');

    await expect(chosen(page, 'filter-health')).toHaveValue('healthy');
    await expect(chosen(page, 'filter-namespace')).toHaveValue('default');
    await expect(chosen(page, 'filter-run')).toHaveValue('flow');
  });

  test('the run filter offers the runs present in the listing', async ({ page }) => {
    await page.getByTestId('filter-run').click();

    await expect(page.getByTestId('filter-run-flow')).toBeVisible();
    await expect(page.getByTestId('filter-run-steps')).toBeVisible();
  });

  test('starts a relay into a namespace chosen on this screen', async ({ live, page }) => {
    const id = uniqueId('pw_idx');

    try {
      await startRelay(page, id, { namespace: 'default' });

      await expect(page.getByTestId(`relay-index-row-${id}`)).toBeVisible();
    } finally {
      // The index lists relays; stopping one is the namespace screen's verb,
      // so cleanup goes there.
      await live('/namespaces/default');
      await stopRelay(page, id);
    }

    await live('/relays');
    await expect(page.getByTestId(`relay-index-row-${id}`)).toHaveCount(0);
  });

  test('starts a steps relay from here, and the listing reports its run', async ({
    live,
    page,
  }) => {
    const id = uniqueId('pw_idxst');

    try {
      await startRelay(page, id, { namespace: 'default', run: 'steps' });

      await expect(page.getByTestId(`relay-index-row-${id}`)).toContainText('steps');
    } finally {
      await live('/namespaces/default');
      await stopRelay(page, id);
    }
  });

  test('the namespace field offers the namespaces the token can reach', async ({ page }) => {
    await page.getByTestId('start-relay-btn').click();
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
