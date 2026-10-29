import {
  menuAction,
  test,
  expect,
  healthBadge,
  healthMatcher,
  choose,
  startRelay,
  startRelayCli,
  stopRelay,
  stopRelayCli,
  SEEDED_FACTORY,
  uniqueId,
  visitLive,
} from './fixtures';
import { CONTROLLERS, machine, SECOND_FACTORY, SECOND_NAMESPACE } from './global-setup';

/**
 * The cross-namespace relays index.
 *
 * The dev stack seeds the flow relay `testnet_store_1` into `default`, so
 * its presence is asserted; a test that needs a steps relay starts its own. Totals are not: the
 * controller's `storage` may carry durable state from earlier campaigns, so
 * any absolute count is somebody else's number. Which rows each filter keeps
 * and which choices it offers are asserted in `relay_index_live_test.exs`.
 */
/**
 * How many relays every namespace holds is the stack's to say, so the listing
 * is narrowed to `default`, where the seeded relays live, rather than relying
 * on them landing on its first page.
 */
const DEFAULT_ONLY = '/relays?namespace=default';

test.describe('Relays index', () => {
  test.beforeEach(async ({ live }) => {
    await live(DEFAULT_ONLY);
  });

  test('lists seeded relays with their namespace, health and run, and a row opens its relay', async ({
    page,
    live,
  }) => {
    await expect(page.getByTestId('relays-index-table')).toBeVisible();

    const row = page.getByTestId('relay-index-row-testnet_store_1');
    await expect(row).toBeVisible();
    await expect(row).toContainText('default');
    await expect(row).toContainText('store_input');
    await expect(row).toContainText('flow');
    await expect(healthBadge(page, 'relay-index-row-testnet_store_1')).toHaveAttribute(
      'data-health',
      healthMatcher(),
    );

    await expect(page.getByTestId('relays-count')).toContainText('across');

    // A row opens its relay in the inspector; its name, Open and its menu open the relay.
    const relayUrl = /\/namespaces\/default\/relays\/testnet_store_1$/;

    await page.getByTestId('relay-index-row-testnet_store_1').click();
    await expect(page.getByTestId('inspector-relay')).toBeVisible();
    await page.getByTestId('inspector-close').click();
    // The drawer leaving widens the table and moves its rows, so the next
    // click waits for it rather than landing on whichever row slid under it.
    await expect(page.getByTestId('inspector-relay')).toHaveCount(0);

    await page.getByTestId('relay-link-testnet_store_1').click();
    await expect(page).toHaveURL(relayUrl);
    await expect(page.getByTestId('inspector-relay')).toHaveCount(0);
    await expect(page.getByTestId('topology-graph')).toBeVisible();

    await live(DEFAULT_ONLY);
    await page.getByTestId('open-relay-testnet_store_1').click();
    await expect(page).toHaveURL(relayUrl);

    await live(DEFAULT_ONLY);
    await menuAction(page, 'relay-menu-testnet_store_1', 'view-relay-testnet_store_1');
    await expect(page).toHaveURL(relayUrl);
    await expect(page.getByTestId('relay-runner')).toBeVisible();
  });

  test('starts a steps relay from here, filters by run, and the back button undoes the filter', async ({
    page,
  }) => {
    const id = uniqueId('pw_idxst');

    try {
      await startRelay(page, id, { namespace: 'default', run: 'steps' });
      await expect(page.getByTestId(`relay-index-row-${id}`)).toContainText('steps');

      await choose(page, 'filter-run', 'steps');
      await expect(page).toHaveURL(/\?.*run=steps/);
      await expect(page.getByTestId(`relay-index-row-${id}`)).toBeVisible();
      await expect(page.getByTestId('relay-index-row-testnet_store_1')).toHaveCount(0);

      await page.goBack();
      await expect(page).not.toHaveURL(/run=steps/);
      await expect(page.getByTestId('relay-index-row-testnet_store_1')).toBeVisible();
    } finally {
      // The index lists relays; stopping one is the namespace screen's verb.
      await stopRelay(page, id);
    }

    await visitLive(page, DEFAULT_ONLY);
    await expect(page.getByTestId(`relay-index-row-${id}`)).toHaveCount(0);
  });

  test('a relay started and stopped elsewhere arrives in the lifecycle feed and the rows', async ({
    page,
  }) => {
    const id = uniqueId('pw_feed');
    const feed = page.getByTestId('lifecycle-feed').locator('li').filter({ hasText: id });

    try {
      await startRelayCli(id, SEEDED_FACTORY.flow);
      await expect(feed.filter({ hasText: `started from ${SEEDED_FACTORY.flow}` })).toHaveCount(1);
      await expect(page.getByTestId(`relay-index-row-${id}`)).toBeVisible();

      await stopRelayCli(id);
      await expect(feed.filter({ hasText: 'stopped:' })).toHaveCount(1);
      await expect(page.getByTestId(`relay-index-row-${id}`)).toHaveCount(0);
    } finally {
      await stopRelayCli(id);
    }
  });

  test('a relay hosted on the other controller shows the health its controller decided and names it', async ({
    page,
  }) => {
    const id = uniqueId('pw_remote');

    try {
      await startRelayCli(id, SECOND_FACTORY, SECOND_NAMESPACE);
      await visitLive(page, `/namespaces/${SECOND_NAMESPACE}/relays`);

      // Unknown only until its controller first judges it, within a second.
      await expect(healthBadge(page, `relay-index-row-${id}`)).toHaveText('Healthy');
      await expect(page.getByTestId(`relay-controller-${id}`)).toHaveText(machine(CONTROLLERS[1]));
      await expect(page.getByTestId(`relay-controller-${id}`)).toHaveAttribute('title', CONTROLLERS[1]);
    } finally {
      await stopRelayCli(id, SECOND_NAMESPACE);
    }
  });
});
