import {
  test,
  expect,
  testIds,
  chosen,
  openSection,
  expectAdvances,
  readFigure,
  sparklineSamples,
  ADVANCE_WINDOW_MS,
  openPage,
  type Page,
} from './fixtures';

/**
 * The pipeline graph and the fleet summary, against the running dev stack.
 *
 * The delta arithmetic, the degradation states and the join are covered in
 * ExUnit, where a snapshot can be dictated. What only a browser can answer is
 * whether the server-rendered SVG actually draws, whether the tick keeps
 * patching it, whether a tap really listens and stops, and whether every node
 * on it reaches the screen that owns it.
 */

const RELAY = '/namespaces/default/relays/testnet_store_1';
const FLOW_BUCKETS = /topo-flow-(idle|slow|medium|fast)/;

/** The test ids of the listener bindings on the relay, read on its plugins panel. */
async function listenerBindings(page: Page): Promise<string[]> {
  return (await testIds(page, 'binding-row-')).filter((id) => id.startsWith('io_listener_'));
}

test.describe('Pipeline graph', () => {
  test.beforeEach(async ({ live }) => {
    await live(RELAY);
  });

  test('draws the record path from ingest to output', async ({ page }) => {
    await expect(page.getByTestId('topology-graph')).toBeVisible();

    await expect(page.getByTestId('topo-node-ingest')).toBeVisible();
    await expect(page.getByTestId('topo-node-testnet_store_1')).toBeVisible();
    await expect(page.getByTestId('topo-node-channel')).toBeVisible();
    await expect(page.getByTestId('topo-node-output')).toBeVisible();

    // The chain is drawn top to bottom, so the output sits below the ingest.
    const ingest = await page.getByTestId('topo-node-ingest').boundingBox();
    const output = await page.getByTestId('topo-node-output').boundingBox();
    expect(output!.y).toBeGreaterThan(ingest!.y);
  });

  test('fits the column it is given rather than being clipped by it', async ({ page }) => {
    const overflow = await page.evaluate(() => {
      const svg = document.querySelector('[data-testid="topology-graph"] svg')!;
      const box = svg.getBoundingClientRect();
      const column = svg.parentElement!.getBoundingClientRect();
      return Math.round(box.right - column.right);
    });

    expect(overflow, 'the graph must not spill out of its column').toBeLessThanOrEqual(0);
  });

  test('names every line style in a legend', async ({ page }) => {
    const legend = page.getByTestId('topology-legend');

    await expect(legend).toBeVisible();
    await expect(legend).toContainText('Records flowing');
    await expect(legend).toContainText('dead-letter');
  });

  test('every flow edge carries a speed bucket, and the seeded traffic moves its rate', async ({
    page,
  }) => {
    const classes = await page
      .locator('[data-testid^="topo-edge-flow-"]')
      .evaluateAll((edges) => edges.map((e) => e.getAttribute('class') ?? ''));

    expect(classes.length).toBeGreaterThan(0);
    classes.forEach((klass) => expect(klass).toMatch(FLOW_BUCKETS));

    // The seeded source feeds this relay, so the edge it forwards on must read
    // a rate above zero on some tick, and leave the idle bucket with it.
    const rate = page.getByTestId('topo-rate-flow-testnet_store_1-channel');
    const edge = page.getByTestId('topo-edge-flow-testnet_store_1-channel');
    await expect
      .poll(
        async () =>
          ((await rate.count()) ? await readFigure(rate) : 0) > 0 &&
          (await edge.getAttribute('class')),
        { message: 'the forwarding edge never showed a rate', timeout: ADVANCE_WINDOW_MS },
      )
      .toMatch(/topo-flow-(slow|medium|fast)/);
  });

  test('the selected relay’s sparkline gains a sample every tick', async ({ page }) => {
    await page.getByTestId('topo-node-testnet_store_1').click();
    await expect(page.getByTestId('topology-sparkline')).toBeVisible({
      timeout: ADVANCE_WINDOW_MS,
    });

    await expectAdvances(() => sparklineSamples(page), 'the sparkline');
  });

  test('selecting the core shows its counters and links to its listen view', async ({ page }) => {
    await page.getByTestId('topo-node-testnet_store_1').click();

    const panel = page.getByTestId('topology-detail');
    await expect(panel).toBeVisible();
    await expect(panel).toContainText('store_input');
    await expect(panel).toContainText('Uptime');

    await page.getByTestId('topology-detail-link').click();

    await expect(page).toHaveURL(new RegExp(`${RELAY}/listen$`));
  });

  test('selecting the channel links through to the cluster screen', async ({ page }) => {
    await page.getByTestId('topo-node-channel').click();

    await expect(page.getByTestId('topology-detail')).toBeVisible();
    await page.getByTestId('topology-detail-link').click();

    await expect(page).toHaveURL(/\/cluster$/);
  });

  test('dismissing the detail panel clears the selection', async ({ page }) => {
    await page.getByTestId('topo-node-testnet_store_1').click();
    await expect(page.getByTestId('topology-detail')).toBeVisible();

    await page.getByTestId('topology-detail-dismiss').click();

    await expect(page.getByTestId('topology-detail')).toHaveCount(0);
  });
});

test.describe('Payload tap', () => {
  test.beforeEach(async ({ live }) => {
    await live(RELAY);
  });

  test('attaches on demand, measures the seeded traffic, and detaches on close', async ({
    page,
  }) => {
    await expect(page.getByTestId('tap-figures')).toHaveCount(0);

    // The seeded source writes into this relay's input.
    await page.getByTestId('topology-tap').getByTestId('tap-input').click();

    // Figures come from the payloads the listener delivers, because nothing on
    // the data plane counts bytes.
    const figures = page.getByTestId('tap-figures');
    await expect(figures).toBeVisible();
    await expectAdvances(page.getByTestId('tap-msg-rate'), 'the tap message rate');
    await expect(page.getByTestId('tap-byte-rate')).not.toHaveText(/^\s*0 B\/s\s*$/);
    await expect(page.getByTestId('tap-recent').locator('li').first()).toBeVisible();

    await page.getByTestId('tap-close').click();

    await expect(page.getByTestId('tap-figures')).toHaveCount(0);
    await expect(page.getByTestId('tap-input')).toBeVisible();
  });

  test('an output tap reports what the relay forwards', async ({ page }) => {
    await page.getByTestId('tap-output').click();

    await expect(page.getByTestId('tap-figures')).toBeVisible();
    await expectAdvances(page.getByTestId('tap-msg-rate'), 'the output tap message rate');
    await page.getByTestId('tap-close').click();
  });

  test('leaves no listener bound to the relay behind it', async ({ page, live }) => {
    await openSection(page, 'plugins');
    const before = await testIds(page, 'binding-row-');

    await page.getByTestId('tap-input').click();
    await expect(page.getByTestId('tap-figures')).toBeVisible();

    // Navigating away is the case an operator actually hits; the controller
    // has to notice the listening page is gone without being told.
    await live('/plugins');
    await live(RELAY);
    await openSection(page, 'plugins');

    await expect
      .poll(() => testIds(page, 'binding-row-'), {
        message: 'the tap must not outlive the page that opened it',
      })
      .toEqual(before);
  });

  test('ends its listener when the page loses its socket', async ({ page, pageHealth }) => {
    pageHealth.allow(/took phx-(client-)?error/, 'the test drops the socket on purpose');
    const watcher = await openPage(page, RELAY);
    await openSection(watcher, 'plugins');
    const before = await listenerBindings(watcher);

    await page.getByTestId('tap-input').click();
    await expect(page.getByTestId('tap-figures')).toBeVisible();
    await expect.poll(() => listenerBindings(watcher)).not.toEqual(before);

    await page.evaluate(() =>
      (window as unknown as { liveSocket: { disconnect(): void } }).liveSocket.disconnect(),
    );

    await expect
      .poll(() => listenerBindings(watcher), {
        message: 'the tap must end with the socket that held it',
        timeout: ADVANCE_WINDOW_MS,
      })
      .toEqual(before);
    await watcher.close();
  });
});

test.describe("Home's map", () => {
  test('the seeded traffic moves a lane’s rate and the wire into it', async ({ page, live }) => {
    await live('/namespaces/default');

    const rate = page.getByTestId('map-rate-testnet_store_1');
    await expect
      .poll(async () => ((await rate.count()) ? await readFigure(rate) : 0), {
        message: 'the seeded relay’s lane never showed a rate',
        timeout: 2 * ADVANCE_WINDOW_MS,
      })
      .toBeGreaterThan(0);

    const wires = page.locator('[data-testid^="map-wire-"][data-testid$="relay-testnet_store_1"]');
    await expect
      .poll(async () => (await wires.evaluateAll((els) => els.map((e) => e.getAttribute('class')))).join(' '), {
        message: 'no wire into the seeded relay moved',
        timeout: ADVANCE_WINDOW_MS,
      })
      .toMatch(/topo-flow-(slow|medium|fast)/);
  });
});
