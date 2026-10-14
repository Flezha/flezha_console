import { test, expect, readFigure, sendToRelay, startRelay, stopRelay, uniqueId, visitLive } from './fixtures';

/**
 * The relay's own graph inside its boundary, against flezha_trader's dev stack.
 *
 * Only that stack runs both cases a browser has to see: the `demo` market
 * group, whose runner announces a graph of fourteen tasklets fed by websocket
 * sources and read by six Kafka producers, and an analyzer runner older than
 * the graph, whose relays fall back to one box. This repository's own stack
 * announces a graph for every factory and runs no market class. The layout,
 * the figures and the fallback's reasons are covered in ExUnit; here a real
 * browser draws them from a real runner.
 *
 *   E2E_MARKET_STACK=1 E2E_BASE_URL=http://localhost:4001 npx playwright test  # both stacks
 *   E2E_MARKET_STACK=1 npx playwright test --project=market
 */

const MARKET = '/namespaces/default/relays/demo%23p0';

/** One Kraken v2 trade frame, as the `trades_in` entry parses it. */
const TRADE_FRAME = JSON.stringify({
  channel: 'trade',
  type: 'update',
  data: [{ symbol: 'BTC/DEMO1', side: 'buy', price: 62345.6, qty: 0.01, timestamp: '2026-08-07T12:34:56.123456Z' }],
});

/** Each output producer of `demo#p0`, with the channels it names. */
const OUTPUTS: Record<string, string[]> = {
  'demo_ohlc#p0': ['ohlc_out'],
  'demo_order_book#p0': ['book_out'],
  'demo_trades#p0': ['trades_out'],
  'demo_ticker_stats#p0': ['ticker_out'],
  'demo_indicators#p0': ['sma_out', 'ema_out', 'rsi_out', 'macd_out', 'boll_out'],
  'demo_market_events#p0': ['price_signal_out', 'volume_signal_out'],
};

test.describe("A relay's data flow", () => {
  test.skip(
    process.env.E2E_MARKET_STACK !== '1',
    "needs flezha_trader's dev stack (its demo market group and analyzer runner): set E2E_MARKET_STACK=1, and E2E_MARKET_URL when its console is not on :4000",
  );

  test('demo#p0 is a boundary around its tasklets, its sources on its entries and its producers on their channels', async ({
    page,
  }) => {
    await visitLive(page, MARKET);

    await expect(page.getByTestId('topology-inside')).toBeVisible();
    await expect(page.getByTestId('term-entry channel')).toBeVisible();
    await expect(page.locator('[data-testid^="topo-node-tasklet-"]')).toHaveCount(14);
    await expect(page.locator('.topo-canvas .topo-boundary')).toHaveCount(1);

    for (const [source, entry] of [
      ['demo_testnet_trade_ws#p0', 'trades_in'],
      ['demo_testnet_book_ws#p0', 'book_in'],
    ]) {
      await expect(page.getByTestId(`topo-node-plugin-${source}-source`)).toBeVisible();
      await expect(page.getByTestId(`topo-edge-wire-plugin-${source}-source-channel-${entry}-${entry}`)).toHaveCount(1);
    }

    const producers = page.locator('[data-testid^="topo-node-plugin-"][data-testid$="-on_output"]');
    await expect(producers).toHaveCount(Object.keys(OUTPUTS).length);

    for (const [producer, channels] of Object.entries(OUTPUTS)) {
      for (const channel of channels) {
        await expect(
          page.getByTestId(`topo-edge-wire-channel-${channel}-plugin-${producer}-on_output-${channel}`),
        ).toHaveCount(1);
      }
    }
    await expect(page.locator('[data-testid*="demo_ohlc"][data-testid*="demo_trades"]')).toHaveCount(0);

    // Plugins stand outside the boundary, tasklets inside it.
    const boundary = (await page.locator('.topo-canvas .topo-boundary-outline').boundingBox())!;
    const ohlc = (await page.getByTestId('topo-node-tasklet-ohlc').boundingBox())!;
    const producer = (await page.getByTestId('topo-node-plugin-demo_ohlc#p0-on_output').boundingBox())!;
    expect(ohlc.x).toBeGreaterThan(boundary.x);
    expect(ohlc.x + ohlc.width).toBeLessThan(boundary.x + boundary.width);
    expect(producer.x).toBeGreaterThan(boundary.x + boundary.width);
  });

  test('a trade sent to its entry gives the ohlc tasklet a rate above zero, and its inspector its figures', async ({
    page,
  }) => {
    await visitLive(page, MARKET);

    // The page's first read is the baseline; the read after the trade makes
    // the first rate, drawn on the one wire into ohlc.
    await sendToRelay(page, TRADE_FRAME, { channel: 'trades_in' });
    const rate = page.getByTestId('topo-rate-wire-channel-trades_in-tasklet-ohlc-trades_in');
    await expect(rate).toHaveText(/\/s/);
    await expect.poll(() => readFigure(rate)).toBeGreaterThan(0);

    await page.getByTestId('topo-node-tasklet-ohlc').click();
    const detail = page.getByTestId('topology-detail');
    await expect(detail).toContainText('Cell mode');
    await expect(page.getByTestId('topology-tasklet-activity')).toContainText('Live Cells');

    await page.getByTestId('topo-node-plugin-demo_indicators#p0-on_output').click();
    await expect(detail).toContainText('sma_out, ema_out, rsi_out, macd_out, boll_out');
    await expect(page.getByTestId('topology-plugin-order')).toContainText('position order');
  });

  test('the graph scrolls inside its panel at a phone and a tablet width', async ({ page }) => {
    for (const width of [390, 768]) {
      await page.setViewportSize({ width, height: 844 });
      await visitLive(page, MARKET);

      const { page: sideways, canvas } = await page.evaluate(() => {
        const el = document.querySelector('[data-testid="topology-canvas"]')!;
        return {
          page: document.documentElement.scrollWidth - document.documentElement.clientWidth,
          canvas: el.scrollWidth - el.clientWidth,
        };
      });

      expect(sideways, `the page must not scroll sideways at ${width}px`).toBeLessThanOrEqual(0);
      expect(canvas, `the graph scrolls inside its panel at ${width}px`).toBeGreaterThan(0);
    }
  });

  test('a relay whose runner announces no graph keeps one box and says why', async ({ page }) => {
    const id = uniqueId('pw_nograph');

    try {
      await visitLive(page, '/namespaces/analyzers/relays');
      await startRelay(page, id, { namespace: 'analyzers', factory: 'momentum_percentile' });
      await visitLive(page, `/namespaces/analyzers/relays/${id}`);

      await expect(page.getByTestId('topology-inside-note')).toContainText(
        'the runners of factory momentum_percentile announced no graph',
      );
      await expect(page.getByTestId(`topo-node-${id}`)).toBeVisible();
      await expect(page.locator('[data-testid^="topo-node-tasklet-"]')).toHaveCount(0);
      await expect(page.getByTestId('topology-inside')).toHaveCount(0);
    } finally {
      await stopRelay(page, id, 'analyzers');
    }
  });
});
