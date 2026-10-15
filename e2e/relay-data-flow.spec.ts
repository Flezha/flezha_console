import { test, expect, expectGraphFits, readFigure, sendToRelay, startRelay, stopRelay, uniqueId, visitLive } from './fixtures';

/**
 * The relay's graph against flezha_trader's dev stack.
 *
 * Only that stack runs both cases a browser has to see: the `demo` market
 * group, whose runner announces a graph of fourteen tasklets fed by websocket
 * sources and read by six Kafka producers, and an analyzer runner older than
 * the graph, whose relays fall back to an empty boundary. The layout, the
 * figures and the fallback's reasons are covered in ExUnit; here a real
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

  test('demo#p0 is a boundary around its tasklets, its sources on its entries and its producers on their channels, left to right', async ({
    page,
  }) => {
    await page.setViewportSize({ width: 1600, height: 900 });
    await visitLive(page, MARKET);

    await expect(page.getByTestId('topology-inside')).toBeVisible();
    await expect(page.locator('[data-testid^="topo-node-tasklet-"]')).toHaveCount(14);
    await expect(page.locator('#topology-svg .topo-boundary-outline')).toHaveCount(1);
    await expect(page.getByTestId('topology-direction')).toHaveText(/left to right \(auto\)/);

    for (const [source, entry] of [
      ['demo_testnet_trade_ws#p0', 'trades_in'],
      ['demo_testnet_book_ws#p0', 'book_in'],
    ]) {
      await expect(page.getByTestId(`topo-node-source-${source}`)).toBeVisible();
      await expect(page.locator(`[data-testid^="topo-wire-source-${source}>"][data-testid$=">${entry}"]`)).toHaveCount(1);
    }

    await expect(page.locator('[data-testid^="topo-node-plugin-demo_"]')).toHaveCount(Object.keys(OUTPUTS).length);
    for (const [producer, channels] of Object.entries(OUTPUTS)) {
      for (const channel of channels) {
        await expect(page.getByTestId(`topo-wire-exit-${channel}>plugin-${producer}>${channel}`)).toHaveCount(1);
      }
    }

    // Plugins stand outside the boundary, tasklets inside it.
    const boundary = (await page.locator('#topology-svg .topo-boundary-outline').boundingBox())!;
    const ohlc = (await page.getByTestId('topo-node-tasklet-ohlc').boundingBox())!;
    const producer = (await page.getByTestId('topo-node-plugin-demo_ohlc#p0').boundingBox())!;
    expect(ohlc.x).toBeGreaterThan(boundary.x);
    expect(ohlc.x + ohlc.width).toBeLessThan(boundary.x + boundary.width);
    expect(producer.x).toBeGreaterThan(boundary.x + boundary.width);
  });

  // The trader stack's runner is built on an SDK older than per-Cell figures,
  // so its sheet says so: the degraded path a newer runner never shows.
  test('a trade sent to its entry gives the ohlc tasklet a rate above zero, and a runner without Cell rows says so', async ({ page }) => {
    await visitLive(page, MARKET);

    await sendToRelay(page, TRADE_FRAME, { channel: 'trades_in' });
    const rate = page.getByTestId('topo-rate-tasklet-ohlc');
    await expect.poll(async () => ((await rate.count()) ? readFigure(rate) : 0)).toBeGreaterThan(0);

    await page.getByTestId('topo-node-tasklet-ohlc').click();
    await expect(page.getByTestId('topology-cells')).toBeVisible();
    await expect(page.getByTestId('cells-not-reported')).toBeVisible();

    await page.getByTestId('topo-node-plugin-demo_indicators#p0').click();
    const detail = page.getByTestId('topology-detail');
    await expect(detail).toContainText('sma_out, ema_out, rsi_out, macd_out, boll_out');
    await expect(page.getByTestId('topology-plugin-order')).toContainText('position order');
  });

  test('the graph fits its panel at a phone and a tablet width', async ({ page }) => {
    for (const width of [390, 768]) {
      await page.setViewportSize({ width, height: 844 });
      await visitLive(page, MARKET);

      await expectGraphFits(page, width);
    }
  });

  test('a relay whose runner announces no graph is an empty boundary and says why', async ({ page }) => {
    const id = uniqueId('pw_nograph');

    try {
      await visitLive(page, '/namespaces/analyzers/relays');
      await startRelay(page, id, { namespace: 'analyzers', factory: 'momentum_percentile' });
      await visitLive(page, `/namespaces/analyzers/relays/${id}`);

      await expect(page.getByTestId('topology-inside-note')).toContainText(
        'the runners of factory momentum_percentile announced no graph',
      );
      await expect(page.getByTestId('topo-node-inside')).toBeVisible();
      await expect(page.locator('[data-testid^="topo-node-tasklet-"]')).toHaveCount(0);
      await expect(page.getByTestId('topology-inside')).toHaveCount(0);
    } finally {
      await stopRelay(page, id, 'analyzers');
    }
  });
});
