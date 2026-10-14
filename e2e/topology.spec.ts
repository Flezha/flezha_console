import {
  ownRelay,
  test,
  expect,
  expectAdvances,
  openPage,
  readFigure,
  sendRecords,
  uniqueId,
  type Page,
} from './fixtures';

/**
 * The pipeline graph, against a relay this file starts and the records it
 * sends that relay.
 *
 * The delta arithmetic, the state word, the timeline, the degradation states
 * and the Home map's rates are covered in ExUnit, where a snapshot can be
 * dictated. What only a browser can answer is whether the server-rendered SVG
 * actually draws, whether the hook flies and lights what a tick pushes,
 * whether a tap really listens and stops, and whether the keyboard and the
 * inspector reach what they name.
 */

const { id: ID } = ownRelay('pw_topo');
const RELAY = `/namespaces/default/relays/${ID}`;
const FLOW_BUCKETS = /topo-flow-(idle|slow|medium|fast)/;


/** One record a run can tell apart, sent to the relay's input. */
function send(tag: string): void {
  sendRecords(ID, [uniqueId(tag)]);
}

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

/**
 * Resolves once a dot matching `selector` is in flight, and with `preview`
 * once that text rides with it. Checked on every frame, since a dot is only in
 * flight for as long as its ride; started before the records are sent, so
 * none flies unseen.
 */
function dotFlies(page: Page, selector: string, preview?: string) {
  return page.waitForFunction(
    ({ selector, preview }) =>
      document.querySelector(`#topology-dots ${selector}[data-flying]`) !== null &&
      (preview === undefined ||
        [...document.querySelectorAll('#topology-dots .topo-dot-preview')].some((label) =>
          label.textContent?.includes(preview),
        )),
    { selector, preview },
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

  test('lays the record path out left to right inside its panel, and opens its legend on demand', async ({
    page,
  }) => {
    await expect(page.getByTestId('topology-graph')).toBeVisible();

    for (const id of ['ingest', ID, 'channel', 'output', 'filtered', 'dead-letter']) {
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

    const overflow = await page.evaluate(() => {
      const canvas = document.querySelector('[data-testid="topology-canvas"]')!;
      return document.documentElement.scrollWidth - document.documentElement.clientWidth +
        Math.round(canvas.getBoundingClientRect().right - canvas.parentElement!.getBoundingClientRect().right);
    });
    expect(overflow, 'the graph must not push the page sideways').toBeLessThanOrEqual(0);

    const legend = page.getByTestId('topology-legend');
    await expect(legend).toBeHidden();
    await page.getByTestId('topology-legend-toggle').click();
    await expect(legend).toBeVisible();
    await expect(legend).toContainText('Records flowing');
    await expect(legend).toContainText('dead-letter');
    await expect(legend).toContainText('A port');
  });

  test('records sent read as a rate and a trickle, and fly hollow dots that light the wires', async ({
    page,
  }) => {
    const flew = dotFlies(page, '.topo-dot--counted');

    // A rate needs the records to land between two ticks, so each read sends
    // one more until a tick has counted one.
    const rate = page.getByTestId('topo-rate-out');
    await expect
      .poll(
        async () => {
          send('pw_rate');
          return (await rate.count()) ? readFigure(rate) : 0;
        },
        { message: 'the OUT port never showed a rate' },
      )
      .toBeGreaterThan(0);

    await flew;
    // The wire a dot crossed is still lit while its light fades.
    await expect.poll(() => brightestWire(page), { message: 'no wire lit up' }).toBeGreaterThan(0.6);
    await expect(page.getByTestId('topology-state-word')).toHaveText(/Trickle/);

    const classes = await page
      .locator('[data-testid^="topo-edge-flow-"]')
      .evaluateAll((edges) => edges.map((e) => e.getAttribute('class') ?? ''));
    expect(classes.length).toBeGreaterThan(0);
    classes.forEach((klass) => expect(klass).toMatch(FLOW_BUCKETS));
  });

  test('under reduced motion a pushed record lights the wires and moves no dot', async ({ page, live }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await live(RELAY);

    await expect
      .poll(
        async () => {
          send('pw_still');
          return brightestWire(page);
        },
        { message: 'no wire lit up' },
      )
      .toBeGreaterThan(0.6);
    // A lit wire means the push was drawn; a dot would have been made with it.
    await expect(page.locator('#topology-dots > *')).toHaveCount(0);
  });

  test('hovering the dead-letter end traces its route and dims the output route', async ({ page }) => {
    await page.getByTestId('topo-node-dead-letter').hover();

    const opacity = (id: string) =>
      page.getByTestId(id).evaluate((el) => Number(getComputedStyle(el).opacity));
    await expect.poll(() => opacity('topo-node-output')).toBeLessThan(0.5);
    expect(await opacity(`topo-node-${ID}`)).toBe(1);
    expect(await opacity('topo-node-ingest')).toBe(1);
  });

  test('selecting a node docks its inspector below, dismissing clears it, and the channel links to the cluster', async ({
    page,
  }) => {
    const canvas = page.getByTestId('topology-canvas');
    const relay = page.getByTestId(`topo-node-${ID}`);
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

    await page.getByTestId('topology-detail-dismiss').click();
    await expect(panel).toHaveCount(0);

    await page.getByTestId('topo-node-channel').click();
    await expect(panel).toBeVisible();
    await page.getByTestId('topology-detail-link').click();
    await expect(page).toHaveURL(/\/cluster$/);
  });

  test('is driven from the keyboard: arrows walk the lanes, Enter selects, Escape clears', async ({ page }) => {
    await page.getByTestId('topo-port-in').focus();
    await expect(page.getByTestId('topo-port-in')).toBeFocused();

    await page.keyboard.press('ArrowRight');
    await expect(page.getByTestId(`topo-node-${ID}`)).toBeFocused();
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

  test('counts what the IN port hears without moving anything, and an OUT tap flies it filled with its payload', async ({
    page,
  }) => {
    const port = page.getByTestId('topo-port-in');
    await port.scrollIntoViewIfNeeded();
    const boxes = await nodeBoxes(page);
    const before = await observers(page, 'in');

    await port.click();

    // Figures come from the payloads the listener delivers, because nothing on
    // the data plane counts bytes.
    await expect(page.getByTestId('tap-figures')).toBeVisible();
    await expect(page.getByTestId('topo-port-state-in')).toHaveText('tapping');
    await expect.poll(() => observers(page, 'in')).toBe(before + 1);
    await expectAdvances(page.getByTestId('tap-msg-count'), 'the tapped message count', () =>
      sendRecords(ID, [uniqueId('pw_tap'), uniqueId('pw_tap'), uniqueId('pw_tap')]),
    );
    await expect(page.getByTestId('tap-msg-rate')).not.toHaveText(/^\s*0(\.0+)?\s*msgs\/s/);
    await expect(page.getByTestId('tap-byte-rate')).not.toHaveText(/^\s*0 B\/s\s*$/);
    await expect(page.getByTestId('tap-recent').locator('li').first()).toBeVisible();
    expect(await nodeBoxes(page)).toEqual(boxes);

    await page.getByTestId('tap-close').click();
    await expect(page.getByTestId('tap-figures')).toHaveCount(0);

    await page.getByTestId('topo-port-out').click();
    await expect(page.getByTestId('tap-figures')).toBeVisible();
    await expect.poll(() => observers(page, 'out')).toBe(1);

    const payload = uniqueId('pw_out');
    const flew = dotFlies(page, '.topo-dot:not(.topo-dot--counted)', payload);
    sendRecords(ID, [payload]);
    await flew;

    await page.getByTestId('tap-close').click();
  });

  test('leaves its port counting the listeners it had before', async ({ page, live }) => {
    const before = await observers(page, 'in');

    await page.getByTestId('topo-port-in').click();
    await expect.poll(() => observers(page, 'in')).toBe(before + 1);

    // Navigating away is the case an operator actually hits; the controller
    // has to notice the listening page is gone without being told.
    await live('/plugins');
    await live(RELAY);

    await expect
      .poll(() => observers(page, 'in'), { message: 'the tap must not outlive the page that opened it' })
      .toBe(before);
  });

  test('ends its listener when the page loses its socket', async ({ page, pageHealth }) => {
    pageHealth.allow(/took phx-(client-)?error/, 'the test drops the socket on purpose');
    const watcher = await openPage(page, RELAY);
    const before = await observers(watcher, 'in');

    await page.getByTestId('topo-port-in').click();
    await expect(page.getByTestId('tap-figures')).toBeVisible();
    await expect.poll(() => observers(watcher, 'in')).toBe(before + 1);

    await page.evaluate(() =>
      (window as unknown as { liveSocket: { disconnect(): void } }).liveSocket.disconnect(),
    );

    await expect
      .poll(() => observers(watcher, 'in'), { message: 'the tap must end with the socket that held it' })
      .toBe(before);
    await watcher.close();
  });
});
