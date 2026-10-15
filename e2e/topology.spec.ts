import {
  expectGraphFits,
  ownRelay,
  test,
  expect,
  expectAdvances,
  openPage,
  sendRecords,
  uniqueId,
  type Page,
} from './fixtures';

/**
 * The pipeline graph, against relays this file starts and the records it
 * sends them: a `static_cell` relay, `testnet_chain`'s shape, and a
 * `showcase` relay, whose graph holds every shape the layout draws.
 *
 * The layout's rules, the delta arithmetic, the Cell rows, the tally and the
 * degradation states are covered in ExUnit, where a snapshot can be dictated.
 * What only a browser can answer is whether the SVG fits and keeps its nodes
 * apart, whether the view controls change only the view, whether the hook
 * moves records in the order they pass, and whether the keyboard, the Cell
 * sheet and a tap reach what they name.
 */

const { id: CHAIN } = ownRelay('pw_topo', { factory: 'static_cell' });
const { id: SHOWCASE } = ownRelay('pw_show', { factory: 'showcase' });
const relay = (id: string) => `/namespaces/default/relays/${id}`;

/** One record a run can tell apart, sent to the chain relay's input. */
function send(tag: string): Promise<void> {
  return sendRecords(CHAIN, [uniqueId(tag)]);
}

async function chooseDirection(page: Page, dir: 'auto' | 'LR' | 'TB'): Promise<void> {
  await page.getByTestId(`topology-dir-${dir}`).click();
  await expect(page.getByTestId(`topology-dir-${dir}`)).toHaveAttribute('aria-pressed', 'true');
  if (dir !== 'auto') { await expect(page.getByTestId('topology-canvas')).toHaveAttribute('data-direction', dir) }
}

/** Every node's box on screen, by node id. */
async function boxes(page: Page): Promise<Record<string, { x: number; y: number; w: number; h: number }>> {
  return page.locator('#topology-svg [data-node]').evaluateAll((nodes) =>
    Object.fromEntries(
      nodes.map((n) => {
        const target = (n.querySelector('.flz-graph-node > rect:last-of-type, .topo-port-ring') ?? n) as Element;
        const b = target.getBoundingClientRect();
        return [n.getAttribute('data-node'), { x: b.x, y: b.y, w: b.width, h: b.height }];
      }),
    ),
  );
}

/** Pairs of boxes that overlap by more than a hairline. */
function overlaps(all: Record<string, { x: number; y: number; w: number; h: number }>): string[] {
  const ids = Object.keys(all).filter((id) => !id.startsWith('entry-') && !id.startsWith('exit-') && id !== 'relay');
  const hits: string[] = [];
  for (const a of ids) {
    for (const b of ids) {
      const [p, q] = [all[a], all[b]];
      if (a < b && p.x < q.x + q.w - 1 && q.x < p.x + p.w - 1 && p.y < q.y + q.h - 1 && q.y < p.y + p.h - 1) {
        hits.push(`${a} × ${b}`);
      }
    }
  }
  return hits;
}

/** Where each node sits in the graph's own coordinates, whatever the view. */
async function placed(page: Page): Promise<string> {
  return page.locator('#topology-svg [data-node] rect, #topology-svg [data-node] circle.topo-port-ring').evaluateAll((els) =>
    JSON.stringify(els.map((e) => [e.getAttribute('x') ?? e.getAttribute('cx'), e.getAttribute('y') ?? e.getAttribute('cy')])),
  );
}

/** A point on the canvas over its bare background, where a drag pans. */
async function background(page: Page): Promise<[number, number]> {
  return page.getByTestId('topology-canvas').evaluate((el) => {
    const box = el.getBoundingClientRect();
    for (let y = box.top + 10; y < box.bottom - 50; y += 20) {
      for (let x = box.left + 10; x < box.right - 70; x += 20) {
        if (document.elementFromPoint(x, y)?.id === 'topology-svg') { return [x, y] as [number, number] }
      }
    }
    throw new Error('the canvas has no bare background');
  });
}

/** When each wire first carried a mark, by wire id, from the motion layer. */
async function launched(page: Page): Promise<Record<string, number>> {
  return page.getByTestId('topology-canvas').evaluate((el) =>
    Object.fromEntries((el as unknown as { flzMotion: { launched: Map<string, number> } }).flzMotion.launched),
  );
}

/** How many listeners an edge of the relay counts; none when it shows no count. */
async function observers(page: Page, edge: 'in' | 'out'): Promise<number> {
  const badge = page.getByTestId(`topo-observers-${edge}`);
  return (await badge.count()) ? Number(await badge.getAttribute('data-count')) : 0;
}

test.describe('Pipeline graph', () => {
  test('draws the relay from its source to its output channel on one line, and opens its legend', async ({
    page,
    live,
  }) => {
    await live(relay('testnet_chain'));
    await chooseDirection(page, 'LR');

    for (const id of ['source-ws_chain', 'entry-input', 'tasklet-static_entry_tasklet', 'tasklet-static_downstream_tasklet', 'exit-kafka', 'unbound-kafka']) {
      await expect(page.getByTestId(`topo-node-${id}`)).toBeVisible();
    }
    await expect(page.getByTestId('topo-node-tasklet-static_downstream_tasklet')).toContainText('static_downstream_tasklet');

    const all = await boxes(page);
    const line = ['source-ws_chain', 'entry-input', 'tasklet-static_entry_tasklet'].map((id) => Math.round(all[id].y + all[id].h / 2));
    expect(new Set(line).size, `source, entry and first tasklet share a line: ${line}`).toBe(1);

    const legend = page.getByTestId('topology-legend');
    await expect(legend).toBeHidden();
    await page.getByTestId('topology-legend-toggle').click();
    await expect(legend).toContainText("its speed is not the record's");
    await expect(legend).toContainText('no plugin bound');
  });

  test('on the showcase, lights a hovered tasklet, keeps every node apart in both directions, and zooms and pans only the view', async ({
    page,
    live,
  }) => {
    await live(relay(SHOWCASE));
    await expect(page.getByTestId('topo-node-run-validate_tick')).toBeVisible();

    await page.getByTestId('topo-node-tasklet-merge_ticks').hover();
    const opacity = (selector: string) =>
      page.locator(selector).first().evaluate((el) => Number(getComputedStyle(el).opacity));
    await expect.poll(() => opacity('[data-net="entry-trades|trades"]')).toBeLessThan(0.5);
    expect(await opacity('[data-net="tasklet-normalize_trade|normalize_trade"]')).toBe(1);
    expect(await opacity('[data-net="tasklet-merge_ticks|ticks"]')).toBe(1);
    expect(await opacity('[data-testid="topo-node-tasklet-merge_ticks"]')).toBe(1);

    for (const dir of ['LR', 'TB'] as const) {
      await chooseDirection(page, dir);
      await page.getByTestId('topology-one').click();
      expect(overlaps(await boxes(page)), `${dir}: nodes overlap`).toEqual([]);
    }

    // Left in TB at one-to-one by the loop above.
    await page.getByTestId('topology-fit').click();
    const before = await placed(page);
    const svg = page.locator('#topology-svg');
    const fitted = await svg.getAttribute('viewBox');

    await page.getByTestId('topology-zoom-in').click();
    await page.getByTestId('topology-zoom-in').click();
    const zoomed = await svg.getAttribute('viewBox');
    expect(zoomed).not.toEqual(fitted);

    const [x, y] = await background(page);
    await page.mouse.move(x, y);
    await page.mouse.down();
    await page.mouse.move(x + 60, y + 40, { steps: 4 });
    await page.mouse.up();
    expect(await svg.getAttribute('viewBox')).not.toEqual(zoomed);
    expect(await placed(page)).toEqual(before);

    await page.getByTestId('topology-fit').click();
    await expect(svg).toHaveAttribute('viewBox', fitted!);

    await page.reload();
    await expect(page.getByTestId('topology-canvas')).toHaveAttribute('data-direction', 'TB');
    await chooseDirection(page, 'auto');
  });

  test('fits its panel without scrolling the page at a desk, a tablet and a phone width', async ({ page, live }) => {
    for (const width of [1280, 768, 390]) {
      await page.setViewportSize({ width, height: 844 });
      await live(relay(SHOWCASE));
      await expect(page.getByTestId('topology-zoom')).not.toHaveText('100%');

      await expectGraphFits(page, width);
    }
  });

  test("is driven from the keyboard, and Enter opens a tasklet's Cells in a sheet that Escape closes, then the selection", async ({
    page,
    live,
  }) => {
    await live(relay(CHAIN));
    await send('pw_cells');
    await chooseDirection(page, 'LR');

    await page.getByTestId('topo-node-entry-input').focus();
    await page.keyboard.press('ArrowRight');
    await expect(page.getByTestId('topo-node-tasklet-static_entry_tasklet')).toBeFocused();
    await page.keyboard.press('ArrowRight');
    await expect(page.getByTestId('topo-node-tasklet-static_downstream_tasklet')).toBeFocused();
    await page.keyboard.press('ArrowLeft');
    await expect(page.getByTestId('topo-node-tasklet-static_entry_tasklet')).toBeFocused();

    await page.keyboard.press('Enter');
    const sheet = page.getByTestId('topology-cells');
    await expect(sheet).toBeVisible();
    for (const key of ['a', 'b', 'c', 'd']) { await expect(page.getByTestId(`cell-${key}`)).toBeVisible() }
    await expect(page.getByTestId('cells-hop-static_downstream_tasklet')).toHaveText('hop → static_downstream_tasklet');

    await page.keyboard.press('Escape');
    await expect(sheet).toHaveCount(0);
    await expect(page.getByTestId('topo-node-tasklet-static_entry_tasklet')).toHaveAttribute('aria-pressed', 'true');
    await page.keyboard.press('Escape');
    await expect(page.getByTestId('topo-node-tasklet-static_entry_tasklet')).toHaveAttribute('aria-pressed', 'false');
  });

  test('records move in the order they pass: no mark leaves on kafka before one crossed hop', async ({ page, live }) => {
    await page.emulateMedia({ reducedMotion: 'no-preference' });
    await live(relay(CHAIN));
    const hop = 'tasklet-static_entry_tasklet>tasklet-static_downstream_tasklet>hop';
    const kafka = 'tasklet-static_downstream_tasklet>exit-kafka>kafka';

    await expect
      .poll(async () => {
        await send('pw_motion');
        return Object.keys(await launched(page));
      }, { message: 'no mark reached the kafka wire' })
      .toContain(kafka);

    const first = await launched(page);
    expect(first[hop], 'a mark crossed hop').toBeDefined();
    expect(first[hop]).toBeLessThan(first[kafka]);
  });

  test('under reduced motion records are counted but no mark moves', async ({ page, live }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await live(relay(CHAIN));

    const rate = page.getByTestId('topo-rate-in-input');
    await expect.poll(async () => { await send('pw_still'); return rate.textContent() }).toMatch(/IN \d/);
    expect(await launched(page)).toEqual({});
  });
});

test.describe('Payload tap', () => {
  // An output tap is seen by its records flying.
  test.use({ contextOptions: { reducedMotion: 'no-preference' } });

  test.beforeEach(async ({ live }) => {
    await live(relay(CHAIN));
  });

  test('counts what an entry hears without moving anything, and an output tap flies its records filled', async ({
    page,
  }) => {
    const port = page.getByTestId('topo-node-entry-input');
    const before = await placed(page);
    const listening = await observers(page, 'in');

    await port.click();

    await expect(page.getByTestId('tap-figures')).toBeVisible();
    await expect(page.getByTestId('topo-tapping-entry-input')).toBeVisible();
    await expect.poll(() => observers(page, 'in')).toBe(listening + 1);
    await expectAdvances(page.getByTestId('tap-msg-count'), 'the tapped message count', () =>
      sendRecords(CHAIN, [uniqueId('pw_tap'), uniqueId('pw_tap'), uniqueId('pw_tap')]),
    );
    await expect(page.getByTestId('tap-byte-rate')).not.toHaveText(/^\s*0 B\/s\s*$/);
    expect(await placed(page)).toEqual(before);

    await page.getByTestId('tap-close').click();
    await expect(page.getByTestId('tap-figures')).toHaveCount(0);

    await page.getByTestId('topo-node-exit-kafka').click();
    await expect(page.getByTestId('tap-figures')).toBeVisible();
    await expect.poll(async () => {
      await send('pw_out');
      return Object.keys(await launched(page)).filter((w) => w.startsWith('exit-kafka>'));
    }).not.toEqual([]);
    await page.getByTestId('tap-close').click();
  });

  // A tap is a listen the page holds, as the graph's own tally is: both go the
  // same way, so this is what proves the relay keeps no listener of a page.
  test('ends its listener when the page is left, and when the page loses its socket', async ({
    page,
    live,
    pageHealth,
  }) => {
    const left = await observers(page, 'in');

    await page.getByTestId('topo-node-entry-input').click();
    await expect.poll(() => observers(page, 'in')).toBe(left + 1);

    await live('/plugins');
    await live(relay(CHAIN));

    await expect
      .poll(() => observers(page, 'in'), { message: 'the tap must not outlive the page that opened it' })
      .toBe(left);

    pageHealth.allow(/took phx-(client-)?error/, 'the test drops the socket on purpose');
    const watcher = await openPage(page, relay(CHAIN));
    const before = await observers(watcher, 'in');

    await page.getByTestId('topo-node-entry-input').click();
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
