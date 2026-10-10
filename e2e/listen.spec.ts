import {
  test,
  expect,
  expectAdvances,
  readFigure,
  sendToRelay,
  uniqueId,
  ADVANCE_WINDOW_MS,
  openPage,
  type Page,
} from './fixtures';

/**
 * The listen screen, against the seeded relays and the traffic the dev stack
 * feeds them.
 *
 * `testnet_store_1` takes the seeded source's trades as inputs and forwards
 * them as outputs. Sends and calls are made from the relay screen in a second
 * page, so the listen keeps running while the console's own controls cause
 * the records it must show. The refused listen is covered in
 * `test/flezha_ui_web/live/listen_live_test.exs`.
 */
const RELAY = '/namespaces/default/relays/testnet_store_1';
const LISTEN_URL = `${RELAY}/listen`;

const SEEDED_SOURCES = [
  ['ws_store_1', 'testnet_store_1'],
  ['ws_store_2', 'testnet_store_2'],
  ['ws_store_3', 'testnet_store_3'],
  ['ws_filter', 'testnet_filter'],
  ['ws_noop', 'testnet_noop'],
];

const count = (page: Page) => page.getByTestId('listen-count');

test.describe('Seeded traffic (precondition)', () => {
  test('the dev stack binds its sources to the seeded relays and they deliver', async ({
    page,
    live,
  }) => {
    await live('/namespaces/default/plugins');
    for (const [source, relay] of SEEDED_SOURCES) {
      await expect(
        page.getByTestId(`plugin-relays-${source}`),
        `the dev stack must bind ${source} to ${relay}; check config/dev.exs and the stack's bootstrap`,
      ).toContainText(relay);
    }

    await live(LISTEN_URL);
    await page.getByTestId('listen-direction-input').click();
    await expect(page.getByTestId('listen-empty').or(page.getByTestId('listen-message').first())).toBeVisible();

    await expectAdvances(
      count(page),
      'the dev stack delivers nothing into testnet_store_1: its seeded source is bound but silent',
    );
  });
});

test.describe('Listen', () => {
  test.beforeEach(async ({ live }) => {
    await live(LISTEN_URL);
  });

  test('attaches to the relay’s outputs and counts what it forwards', async ({ page }) => {
    await expect(page.getByTestId('listen-error')).toHaveCount(0);
    await expect(page.getByTestId('listen-direction-output')).toHaveAttribute('aria-pressed', 'true');

    await expectAdvances(count(page), 'the output listen count');
    await expect(page.getByTestId('listen-message').first()).toHaveAttribute('data-kind', 'output');
  });

  test('a send from the relay screen arrives on the input side', async ({ page }) => {
    await page.getByTestId('listen-direction-input').click();
    await expect(page.getByTestId('listen-direction-input')).toHaveAttribute('aria-pressed', 'true');
    await expect(page.getByTestId('listen-connecting')).toHaveCount(0);

    const payload = uniqueId('pw_listen');
    const relay = await openPage(page, RELAY);
    await sendToRelay(relay, payload);
    await relay.close();

    const row = page.getByTestId('listen-message').filter({ hasText: payload });
    await expect(row).toHaveAttribute('data-kind', 'input', { timeout: ADVANCE_WINDOW_MS });
  });

  test('a call to the orders relay’s place channel arrives on its output side', async ({
    page,
    live,
  }) => {
    await live('/namespaces/default/relays/orders/listen');
    await expect(page.getByTestId('listen-connecting')).toHaveCount(0);

    const pair = uniqueId('PWL');
    const orders = await openPage(page, '/namespaces/default/relays/orders');
    await orders.getByTestId('talk-open-btn').click();
    await orders.getByTestId('talk-channel-pick').selectOption('place');
    await orders.getByTestId('talk-field-pair').fill(pair);
    await orders.getByTestId('talk-field-amount').fill('1');
    await orders.getByTestId('talk-channel-submit').click();
    await expect(orders.getByTestId('talk-answer').first()).toContainText(pair, { timeout: 20_000 });
    await orders.close();

    const row = page.getByTestId('listen-message').filter({ hasText: pair });
    await expect(row.first()).toHaveAttribute('data-kind', 'output', { timeout: ADVANCE_WINDOW_MS });
  });

  test('pausing freezes the feed while the count keeps going, and resuming thaws it', async ({
    page,
  }) => {
    await expect(page.getByTestId('listen-message').first()).toBeVisible({ timeout: ADVANCE_WINDOW_MS });

    const pause = page.getByTestId('listen-pause');
    await pause.click();
    await expect(pause).toHaveAttribute('aria-pressed', 'true');
    await expect(count(page)).toContainText('(paused)');

    const shown = await page.getByTestId('listen-message').count();
    await expectAdvances(count(page), 'the count while paused');
    await expect(page.getByTestId('listen-message')).toHaveCount(shown);

    await pause.click();
    await expect(pause).toHaveAttribute('aria-pressed', 'false');
    await expect(count(page)).not.toContainText('(paused)');
    await expectAdvances(() => page.getByTestId('listen-message').count(), 'the feed after resuming');
  });

  test('the filter narrows the feed, says when nothing matches, and refuses a bad pattern', async ({
    page,
  }) => {
    await expect(page.getByTestId('listen-message').first()).toBeVisible({ timeout: ADVANCE_WINDOW_MS });
    const all = await page.getByTestId('listen-message').count();

    await page.getByTestId('listen-filter').fill('no_message_matches_this');
    await expect(page.getByTestId('listen-message')).toHaveCount(0);
    await expect(page.getByTestId('listen-empty')).toBeVisible();

    await page.getByTestId('listen-filter').fill('[');
    await expect(page.getByTestId('listen-filter-error')).toContainText('Not a regular expression');
    await expect.poll(() => page.getByTestId('listen-message').count()).toBeGreaterThanOrEqual(all);

    await page.getByTestId('listen-filter').fill('');
    await expect(page.getByTestId('listen-filter-error')).toHaveCount(0);
  });

  test('clearing empties the feed and the count, which then counts again', async ({ page }) => {
    await expect(page.getByTestId('listen-message').first()).toBeVisible({ timeout: ADVANCE_WINDOW_MS });

    await page.getByTestId('listen-clear').click();
    await expect(count(page)).toContainText(/^\s*0 messages received/);
    await expect(page.getByTestId('listen-empty')).toBeVisible();

    await expectAdvances(count(page), 'the count after clearing');
  });

  test('switching direction starts over on the other side', async ({ page }) => {
    await expectAdvances(count(page), 'the output count');

    await page.getByTestId('listen-direction-input').click();
    await expect(page.getByTestId('listen-direction-input')).toHaveAttribute('aria-pressed', 'true');
    await expect(page.getByTestId('listen-direction-output')).toHaveAttribute('aria-pressed', 'false');
    expect(await readFigure(count(page))).toBeLessThanOrEqual(1);
    await expect(page.getByTestId('listen-message').first()).toHaveAttribute('data-kind', 'input', {
      timeout: ADVANCE_WINDOW_MS,
    });
  });

  test('the feed stays pinned to the newest record', async ({ page }) => {
    // The box fills from the seeded traffic alone, a record every few seconds.
    test.setTimeout(90_000);
    await page.setViewportSize({ width: 1280, height: 420 });
    const feed = page.getByTestId('listen-feed');
    const pinned = () =>
      feed.evaluate((el) => el.scrollHeight <= el.clientHeight || el.scrollTop + el.clientHeight >= el.scrollHeight - 2);

    await expect
      .poll(() => feed.evaluate((el) => el.scrollHeight > el.clientHeight), {
        message: 'the feed never filled its box',
        timeout: 60_000,
      })
      .toBe(true);

    await feed.evaluate((el) => (el.scrollTop = 0));
    await expectAdvances(count(page), 'the output count');
    await expect.poll(pinned).toBe(true);
  });

  test('navigates back to the relay', async ({ page }) => {
    await page.getByTestId('relay-tab-detail').click();
    await expect(page).toHaveURL(/\/namespaces\/default\/relays\/testnet_store_1$/);
    await expect(page.getByTestId('topology-graph')).toBeVisible();
  });
});
