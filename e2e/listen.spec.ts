import {
  ownRelay,
  test,
  expect,
  expectAdvances,
  openPage,
  sendRecords,
  sendToRelay,
  uniqueId,
  type Page,
} from './fixtures';

/**
 * The listen screen, against a relay this file starts and the records it
 * sends that relay.
 *
 * The relay runs `store_input`, which forwards each input as an output. Sends
 * from the relay screen are made in a second page, so the listen keeps running
 * while the console's own controls cause the records it must show. Pausing,
 * clearing, filtering and the refused listen are covered in
 * `test/flezha_ui_web/live/listen_live_test.exs`.
 */
const { id: ID } = ownRelay('pw_listen');
const RELAY = `/namespaces/default/relays/${ID}`;
const LISTEN_URL = `${RELAY}/listen`;


const count = (page: Page) => page.getByTestId('listen-count');
const messages = (page: Page) => page.getByTestId('listen-message');

/** Waits until the listener is attached, so nothing sent after it is missed. */
async function attached(page: Page): Promise<void> {
  await expect(page.getByTestId('listen-connecting')).toHaveCount(0);
  await expect(page.getByTestId('listen-error')).toHaveCount(0);
}

test.describe('Listen', () => {
  test.beforeEach(async ({ live, page }) => {
    await live(LISTEN_URL);
    await attached(page);
  });

  test('attaches to a relay’s outputs and shows what it forwards, and what a call to orders places', async ({
    page,
    live,
  }) => {
    await expect(page.getByTestId('listen-direction-output')).toHaveAttribute('aria-pressed', 'true');

    const payload = uniqueId('pw_out');
    await expectAdvances(count(page), 'the output listen count', () => sendRecords(ID, [payload]));
    await expect(messages(page).filter({ hasText: payload })).toHaveAttribute('data-kind', 'output');

    await live('/namespaces/default/relays/orders/listen');
    await attached(page);

    const pair = uniqueId('PWL');
    const orders = await openPage(page, '/namespaces/default/relays/orders');
    await orders.getByTestId('talk-open-btn').click();
    await orders.getByTestId('talk-channel-pick').selectOption('place');
    await orders.getByTestId('talk-field-pair').fill(pair);
    await orders.getByTestId('talk-field-amount').fill('1');
    await orders.getByTestId('talk-channel-submit').click();
    await expect(orders.getByTestId('talk-answer').first()).toContainText(pair);
    await orders.close();

    await expect(messages(page).filter({ hasText: pair }).first()).toHaveAttribute('data-kind', 'output');
  });

  test('switching to the input side starts over, and a send from the relay screen arrives there', async ({
    page,
  }) => {
    await expectAdvances(count(page), 'the output count', () => sendRecords(ID, [uniqueId('pw_out')]));

    await page.getByTestId('listen-direction-input').click();
    await expect(page.getByTestId('listen-direction-input')).toHaveAttribute('aria-pressed', 'true');
    await expect(page.getByTestId('listen-direction-output')).toHaveAttribute('aria-pressed', 'false');
    await attached(page);
    await expect(count(page)).toContainText(/^\s*0\s+messages received/);

    const payload = uniqueId('pw_in');
    const relay = await openPage(page, RELAY);
    await sendToRelay(relay, payload);
    await relay.close();

    await expect(messages(page).filter({ hasText: payload })).toHaveAttribute('data-kind', 'input');
  });

  test('the feed stays pinned to the newest record', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 420 });
    const feed = page.getByTestId('listen-feed');
    const pinned = () =>
      feed.evaluate((el) => el.scrollHeight <= el.clientHeight || el.scrollTop + el.clientHeight >= el.scrollHeight - 2);

    // More records than the box holds at this height.
    sendRecords(ID, Array.from({ length: 30 }, () => uniqueId('pw_fill')));
    await expect(count(page)).toContainText(/^\s*30\s+messages received/);
    expect(await feed.evaluate((el) => el.scrollHeight > el.clientHeight), 'the feed never filled its box').toBe(true);

    await feed.evaluate((el) => (el.scrollTop = 0));
    await expectAdvances(count(page), 'the output count', () => sendRecords(ID, [uniqueId('pw_last')]));
    await expect.poll(pinned).toBe(true);
  });
});
