import {
  test,
  expect,
  expectAdvances,
  readFigure,
  timelineSamples,
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

/**
 * Every node's box, measured from the canvas, to compare before and after
 * something that must not move it. Opening a dock panel may scroll the page to
 * reveal it, which moves the canvas and the nodes together.
 */
async function nodeBoxes(page: Page): Promise<string> {
  return page
    .locator('[data-testid^="topo-node-"]')
    .evaluateAll((nodes) => {
      const canvas = document.querySelector('[data-testid="topology-canvas"]')!.getBoundingClientRect();
      return JSON.stringify(
        nodes.map((n) => {
          const b = n.getBoundingClientRect();
          return [
            n.getAttribute('data-testid'),
            Math.round(b.x - canvas.x),
            Math.round(b.y - canvas.y),
            Math.round(b.width),
          ];
        }),
      );
    });
}

/** How many listeners a port counts; none when its badge is absent. */
async function observers(page: Page, port: 'in' | 'out'): Promise<number> {
  const badge = page.getByTestId(`topo-observers-${port}`);
  return (await badge.count()) ? readFigure(badge) : 0;
}

/** Whether a dot matching `selector` is in flight on the canvas within the window. */
async function dotFlies(page: Page, selector: string): Promise<boolean> {
  return page.evaluate(
    async ({ selector, ms }) => {
      const end = Date.now() + ms;
      while (Date.now() < end) {
        if (document.querySelector(`#topology-dots ${selector}[data-flying]`)) return true;
        await new Promise((r) => setTimeout(r, 50));
      }
      return false;
    },
    { selector, ms: 15_000 },
  );
}

/** The highest stroke opacity among the record lane's wires; a still wire sits at 0.5. */
async function brightestWire(page: Page): Promise<number> {
  return page
    .locator('.topo-wire[data-flow="in"], .topo-wire[data-flow="out"]')
    .evaluateAll((wires) => Math.max(...wires.map((w) => Number(getComputedStyle(w).strokeOpacity))));
}

test.describe('Pipeline graph', () => {
  test.beforeEach(async ({ live }) => {
    await live(RELAY);
  });

  test('lays the record path out left to right, with both ports and both ends of the failures lane', async ({
    page,
  }) => {
    await expect(page.getByTestId('topology-graph')).toBeVisible();

    for (const id of ['ingest', 'testnet_store_1', 'channel', 'output', 'filtered', 'dead-letter']) {
      await expect(page.getByTestId(`topo-node-${id}`)).toBeVisible();
    }
    await expect(page.getByTestId('topo-port-in')).toBeVisible();
    await expect(page.getByTestId('topo-port-out')).toBeVisible();

    const ingest = await page.getByTestId('topo-node-ingest').boundingBox();
    const output = await page.getByTestId('topo-node-output').boundingBox();
    const parked = await page.getByTestId('topo-node-dead-letter').boundingBox();
    expect(output!.x).toBeGreaterThan(ingest!.x);
    expect(Math.round(output!.y)).toBe(Math.round(ingest!.y));
    expect(parked!.y).toBeGreaterThan(ingest!.y);
  });

  test('scrolls the canvas inside its panel rather than the page', async ({ page }) => {
    const overflow = await page.evaluate(() => {
      const canvas = document.querySelector('[data-testid="topology-canvas"]')!;
      return document.documentElement.scrollWidth - document.documentElement.clientWidth +
        Math.round(canvas.getBoundingClientRect().right - canvas.parentElement!.getBoundingClientRect().right);
    });

    expect(overflow, 'the graph must not push the page sideways').toBeLessThanOrEqual(0);
  });

  test('opens its legend on demand', async ({ page }) => {
    const legend = page.getByTestId('topology-legend');
    await expect(legend).toBeHidden();

    await page.getByTestId('topology-legend-toggle').click();

    await expect(legend).toBeVisible();
    await expect(legend).toContainText('Records flowing');
    await expect(legend).toContainText('dead-letter');
    await expect(legend).toContainText('A port');
  });

  test('every wire carries a speed bucket, and the seeded traffic reads a rate above zero', async ({ page }) => {
    const classes = await page
      .locator('[data-testid^="topo-edge-flow-"]')
      .evaluateAll((edges) => edges.map((e) => e.getAttribute('class') ?? ''));

    expect(classes.length).toBeGreaterThan(0);
    classes.forEach((klass) => expect(klass).toMatch(FLOW_BUCKETS));

    // The seeded source writes one record every five seconds, which the
    // smoothed rate shows as a figure rather than 0.0/s.
    const rate = page.getByTestId('topo-rate-out');
    await expect
      .poll(async () => ((await rate.count()) ? await readFigure(rate) : 0), {
        message: 'the OUT port never showed a rate',
        timeout: 2 * ADVANCE_WINDOW_MS,
      })
      .toBeGreaterThan(0);
  });

  test('with no tap open, the counters move hollow dots along the path, which light it', async ({ page }) => {
    expect(await dotFlies(page, '.topo-dot--counted'), 'no counted dot flew').toBe(true);

    // The wire a dot crossed is still lit while its light fades.
    await expect
      .poll(() => brightestWire(page), { message: 'no wire lit up', timeout: ADVANCE_WINDOW_MS })
      .toBeGreaterThan(0.6);
  });

  test('under reduced motion no dot moves, and the wires still light', async ({ page, live }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await live(RELAY);

    await expect
      .poll(() => brightestWire(page), { message: 'no wire lit up', timeout: 2 * ADVANCE_WINDOW_MS })
      .toBeGreaterThan(0.6);
    expect(await dotFlies(page, '.topo-dot')).toBe(false);
  });

  test('says what the relay is doing, and its timeline gains a sample every tick', async ({ page }) => {
    await expect(page.getByTestId('topology-state-word')).toHaveText(/Streaming|Trickle|Quiet|Failing|Stuck/);
    await expect
      .poll(() => page.getByTestId('topology-state-word').textContent(), { timeout: 2 * ADVANCE_WINDOW_MS })
      .toMatch(/Trickle/);

    await expectAdvances(() => timelineSamples(page), 'the timeline');
  });

  test('hovering the dead-letter end traces its route and dims the output route', async ({ page }) => {
    await page.getByTestId('topo-node-dead-letter').hover();

    const opacity = (id: string) =>
      page.getByTestId(id).evaluate((el) => Number(getComputedStyle(el).opacity));
    await expect.poll(() => opacity('topo-node-output')).toBeLessThan(0.5);
    expect(await opacity('topo-node-testnet_store_1')).toBe(1);
    expect(await opacity('topo-node-ingest')).toBe(1);
  });

  test('selecting a node docks its inspector below and leaves the canvas where it was', async ({ page }) => {
    const canvas = page.getByTestId('topology-canvas');
    const relay = page.getByTestId('topo-node-testnet_store_1');
    // In view first, so the click scrolls nothing and any move is the canvas's own.
    await relay.scrollIntoViewIfNeeded();
    const before = await canvas.boundingBox();

    await relay.click();

    const panel = page.getByTestId('topology-detail');
    await expect(panel).toBeVisible();
    await expect(panel).toContainText('store_input');
    await expect(panel).toContainText('Uptime');
    expect(await canvas.boundingBox()).toEqual(before);
    expect((await panel.boundingBox())!.y).toBeGreaterThan(before!.y + before!.height);

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

  test('is driven from the keyboard: arrows walk the lanes, Enter selects, Escape clears', async ({ page }) => {
    await page.getByTestId('topo-port-in').focus();
    await expect(page.getByTestId('topo-port-in')).toBeFocused();

    await page.keyboard.press('ArrowRight');
    await expect(page.getByTestId('topo-node-testnet_store_1')).toBeFocused();
    await page.keyboard.press('ArrowRight');
    await expect(page.getByTestId('topo-port-out')).toBeFocused();
    await page.keyboard.press('ArrowRight');
    await expect(page.getByTestId('topo-node-channel')).toBeFocused();
    await page.keyboard.press('ArrowLeft');
    await page.keyboard.press('ArrowLeft');

    await page.keyboard.press('Enter');
    await expect(page.getByTestId('topology-detail')).toContainText('store_input');

    await page.keyboard.press('Escape');
    await expect(page.getByTestId('topology-detail')).toHaveCount(0);
    await expect(page.getByTestId('topology-tap')).toHaveCount(0);
  });
});

test.describe('Payload tap', () => {
  test.beforeEach(async ({ live }) => {
    await live(RELAY);
  });

  test('opens from the IN port, counts its listener there, and moves nothing', async ({ page }) => {
    const port = page.getByTestId('topo-port-in');
    await port.scrollIntoViewIfNeeded();
    const boxes = await nodeBoxes(page);
    const before = await observers(page, 'in');

    await port.click();

    // Figures come from the payloads the listener delivers, because nothing on
    // the data plane counts bytes.
    await expect(page.getByTestId('tap-figures')).toBeVisible();
    await expect(page.getByTestId('topo-port-state-in')).toHaveText('tapping');
    await expect.poll(() => observers(page, 'in'), { timeout: ADVANCE_WINDOW_MS }).toBe(before + 1);
    // The count is what advances; a steady rate only holds above zero.
    await expectAdvances(page.getByTestId('tap-msg-count'), 'the tapped message count');
    await expect(page.getByTestId('tap-msg-rate')).not.toHaveText(/^\s*0(\.0+)?\s*msgs\/s/);
    await expect(page.getByTestId('tap-byte-rate')).not.toHaveText(/^\s*0 B\/s\s*$/);
    await expect(page.getByTestId('tap-recent').locator('li').first()).toBeVisible();
    expect(await nodeBoxes(page)).toEqual(boxes);

    await page.getByTestId('tap-close').click();

    await expect(page.getByTestId('tap-figures')).toHaveCount(0);
  });

  test('an output tap draws the records it hears filled, with their payload', async ({ page }) => {
    await page.getByTestId('topo-port-out').click();

    await expect(page.getByTestId('tap-figures')).toBeVisible();
    expect(await dotFlies(page, '.topo-dot:not(.topo-dot--counted)'), 'no tapped dot flew').toBe(true);
    await expect(page.locator('#topology-dots .topo-dot-preview').first()).toContainText('store_1', {
      timeout: ADVANCE_WINDOW_MS,
    });
    await page.getByTestId('tap-close').click();
  });

  test('leaves its port counting the listeners it had before', async ({ page, live }) => {
    const before = await observers(page, 'in');

    await page.getByTestId('topo-port-in').click();
    await expect.poll(() => observers(page, 'in'), { timeout: ADVANCE_WINDOW_MS }).toBe(before + 1);

    // Navigating away is the case an operator actually hits; the controller
    // has to notice the listening page is gone without being told.
    await live('/plugins');
    await live(RELAY);

    await expect
      .poll(() => observers(page, 'in'), {
        message: 'the tap must not outlive the page that opened it',
        timeout: ADVANCE_WINDOW_MS,
      })
      .toBe(before);
  });

  test('ends its listener when the page loses its socket', async ({ page, pageHealth }) => {
    pageHealth.allow(/took phx-(client-)?error/, 'the test drops the socket on purpose');
    const watcher = await openPage(page, RELAY);
    const before = await observers(watcher, 'in');

    await page.getByTestId('topo-port-in').click();
    await expect(page.getByTestId('tap-figures')).toBeVisible();
    await expect.poll(() => observers(watcher, 'in'), { timeout: ADVANCE_WINDOW_MS }).toBe(before + 1);

    await page.evaluate(() =>
      (window as unknown as { liveSocket: { disconnect(): void } }).liveSocket.disconnect(),
    );

    await expect
      .poll(() => observers(watcher, 'in'), {
        message: 'the tap must end with the socket that held it',
        timeout: ADVANCE_WINDOW_MS,
      })
      .toBe(before);
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
