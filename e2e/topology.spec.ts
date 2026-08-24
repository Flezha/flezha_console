import { test, expect, testIds, chosen } from './fixtures';

/**
 * The pipeline graph and the fleet summary, against the running dev stack.
 *
 * The delta arithmetic, the degradation states and the join are covered in
 * ExUnit, where a snapshot can be dictated. What only a browser can answer is
 * whether the server-rendered SVG actually draws, whether the tick keeps
 * patching it, whether a tap really attaches and detaches, and whether every
 * entity on it reaches the screen that owns it.
 */

const OPERATIVE = '/namespaces/default/operatives/testnet_store_1';
const FLOW_BUCKETS = /topo-flow-(idle|slow|medium|fast)/;

test.describe('Pipeline graph', () => {
  test.beforeEach(async ({ live }) => {
    await live(OPERATIVE);
  });

  test('draws the record path from ingest to output', async ({ page }) => {
    await expect(page.getByTestId('topology-graph')).toBeVisible();

    await expect(page.getByTestId('topo-node-ingest')).toBeVisible();
    await expect(page.getByTestId('topo-node-testnet_store_1')).toBeVisible();
    await expect(page.getByTestId('topo-node-channel')).toBeVisible();
    await expect(page.getByTestId('topo-node-output')).toBeVisible();

    // The chain is drawn top to bottom, so the sink sits below the source.
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

  test('every flow edge carries a speed bucket, and rates appear once the tick has a baseline', async ({
    page,
  }) => {
    // A rate figure can only exist after two snapshots were diffed, so its
    // arrival is the tick doing its job — not merely the first render.
    await expect(page.locator('[data-testid^="topo-rate-"]').first()).toBeVisible({
      timeout: 15_000,
    });

    const classes = await page
      .locator('[data-testid^="topo-edge-flow-"]')
      .evaluateAll((edges) => edges.map((e) => e.getAttribute('class') ?? ''));

    expect(classes.length).toBeGreaterThan(0);
    classes.forEach((klass) => expect(klass).toMatch(FLOW_BUCKETS));
  });

  test('selecting the core shows its counters and links to the live stream', async ({ page }) => {
    await page.getByTestId('topo-node-testnet_store_1').click();

    const panel = page.getByTestId('topology-detail');
    await expect(panel).toBeVisible();
    await expect(panel).toContainText('store_input');
    await expect(panel).toContainText('Uptime');

    await page.getByTestId('topology-detail-link').click();

    await expect(page).toHaveURL(new RegExp(`${OPERATIVE}/stream$`));
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
    await live(OPERATIVE);
  });

  test('attaches on demand, reports what it measured, and detaches on close', async ({ page }) => {
    await expect(page.getByTestId('tap-figures')).toHaveCount(0);

    await page.getByTestId('tap-output').click();

    // Figures come from the payloads the listener delivers, because nothing on
    // the data plane counts bytes.
    const figures = page.getByTestId('tap-figures');
    await expect(figures).toBeVisible();
    await expect(figures).toContainText('Messages');
    await expect(page.getByTestId('tap-msg-rate')).toContainText('/s');
    await expect(page.getByTestId('tap-byte-rate')).toContainText('/s');

    await page.getByTestId('tap-close').click();

    await expect(page.getByTestId('tap-figures')).toHaveCount(0);
    await expect(page.getByTestId('tap-output')).toBeVisible();
  });

  test('leaves no listener attached to the controller behind it', async ({ page, live }) => {
    await page.getByTestId('tap-input').click();
    await expect(page.getByTestId('tap-figures')).toBeVisible();

    // Navigating away is the case an operator actually hits; the bridge has to
    // notice the viewer is gone without being told.
    await live('/plugins');

    const attached = page.locator('[data-testid^="plugin-row-io_listener"]');
    await expect(attached, 'the tap must not outlive the page that opened it').toHaveCount(0);
  });
});

test.describe('Fleet summary', () => {
  test('reports the namespace data plane on the dashboard', async ({ page, live }) => {
    await live('/');

    await expect(page.getByTestId('topology-summary')).toBeVisible();
    await expect(page.getByTestId('summary-operatives')).toHaveText(/^\s*\d+\s*$/);
    await expect(page.getByTestId('summary-runners')).toHaveText(/^\s*\d+\s*$/);
    await expect(page.getByTestId('summary-backpressure')).toHaveText(/^\s*\d+\s*$/);
    await expect(page.getByTestId('summary-parked')).toHaveText(/^\s*\d+\s*$/);
    await expect(chosen(page, 'topology-namespace')).toHaveValue('default');
  });

  test('lists the busiest operatives, each linking to its own pipeline', async ({ page, live }) => {
    await live('/');

    await expect(page.getByTestId('summary-busiest')).toBeVisible({ timeout: 15_000 });

    const ranked = await testIds(page, 'summary-operative-');
    expect(ranked.length).toBeGreaterThan(0);

    await page.getByTestId(`summary-operative-${ranked[0]}`).click();

    await expect(page).toHaveURL(new RegExp(`/namespaces/default/operatives/${ranked[0]}$`));
    await expect(page.getByTestId('topology-graph')).toBeVisible();
  });

  test('is embedded on the namespace page without a namespace selector', async ({ page, live }) => {
    await live('/namespaces/default');

    await expect(page.getByTestId('topology-summary')).toBeVisible();
    await expect(page.getByTestId('topology-namespace')).toHaveCount(0);
  });

  test('breaks its counts down by health, each bucket linking out', async ({ page, live }) => {
    await live('/');

    const health = page.getByTestId('summary-health');
    await expect(health).toBeVisible();

    const buckets = page.locator('[data-testid^="summary-health-"]');
    expect(await buckets.count()).toBeGreaterThan(0);

    const first = buckets.first();
    await expect(first).toHaveAttribute('href', /\/operatives\?/);

    await first.click();
    await expect(page).toHaveURL(/\/operatives\?/);
    await expect(chosen(page, 'filter-health')).not.toHaveValue('');
  });

  test('surfaces an idle non-healthy operative despite zero throughput', async ({ page, live }) => {
    await live('/');

    // The seeded chat workflow is parked, so it never advances a counter.
    const attention = page.getByTestId('summary-attention');
    await expect(attention).toBeVisible();
    await expect(page.getByTestId('summary-attention-testnet_chat')).toBeVisible();
  });
});
