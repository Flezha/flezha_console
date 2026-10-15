import { test, expect, openSection, closeSection, cliCall, uniqueId, type Page } from './fixtures';

/**
 * The relay screen's Calls panel on the seeded `orders` relay, whose `place`
 * channel answers an order and whose `audit` channel answers nothing.
 *
 * Calls from outside the console go through `cliCall()`, the request `flz`
 * sends, so the controller names them `cli`. Every row is found by a pair or
 * payload unique to the test, never by a guessed call id. Nothing is left
 * behind: a call is an input the relay consumes.
 */

const ORDERS = ['default', 'orders'];

function placeFromCli(pair: string): Promise<unknown> {
  return cliCall('Relay.call_channel', [...ORDERS, 'place', { pair, amount: 1 }, { deadline_ms: 20000 }]);
}

function callRow(page: Page, text: string) {
  return page.locator('[data-testid^="call-entry-"]').filter({ hasText: text });
}

/** Opens the panel and waits until the controller holds its listen. */
async function openCalls(page: Page): Promise<void> {
  await openSection(page, 'calls');
  await expect(page.getByTestId('calls-listening')).toBeVisible();
}

test.describe('Calls to a relay', () => {
  test.beforeEach(async ({ live }) => {
    await live('/namespaces/default/relays/orders');
  });

  test('each call is listed with its source, channel, outcome, answer and duration', async ({
    page,
  }) => {
    await openCalls(page);
    const cli = uniqueId('CLI');
    const ui = uniqueId('UI');
    const unanswered = uniqueId('unanswered');

    expect(await placeFromCli(cli)).toMatchObject({ answer: { status: 'placed', pair: cli } });

    const fromCli = callRow(page, cli).first();
    await expect(fromCli.locator('[data-testid^="call-source-"]')).toHaveText('CLI');
    await expect(fromCli).toContainText('place');
    await expect(fromCli.locator('[data-testid^="call-outcome-"]')).toHaveText('Answered');
    await expect(fromCli).toContainText('"status":"placed"');
    await expect(fromCli).toContainText(/\d+(ms|s)\b/);

    await page.getByTestId('talk-open-btn').click();
    await page.getByTestId('talk-channel-pick').selectOption('place');
    await page.getByTestId('talk-field-pair').fill(ui);
    await page.getByTestId('talk-field-amount').fill('1');
    await page.getByTestId('talk-channel-submit').click();
    await expect(page.getByTestId('talk-answer').first()).toContainText(ui);

    // `audit` answers nothing, so a short deadline runs out.
    await page.getByTestId('talk-mode-raw').click();
    await page.getByTestId('talk-payload').fill(unanswered);
    await page.getByTestId('talk-channel').fill('audit');
    await page.getByTestId('talk-deadline').fill('500');
    await page.getByTestId('talk-call-btn').click();
    await expect(page.getByTestId('talk-result').first()).toContainText('call.timeout');
    await page.getByTestId('talk-close-btn').click();

    const fromUi = callRow(page, ui).first();
    await expect(fromUi.locator('[data-testid^="call-source-"]')).toHaveText('UI');
    await expect(fromUi.locator('[data-testid^="call-outcome-"]')).toHaveText('Answered');

    const timedOut = callRow(page, unanswered).first();
    await expect(timedOut.locator('[data-testid^="call-outcome-"]')).toHaveText('Timed out');
    await expect(timedOut).toContainText('call.timeout');
  });

  test('a folded panel listens to nothing', async ({ page }) => {
    await openCalls(page);
    await closeSection(page, 'calls');

    const unheard = uniqueId('FOLDED');
    await placeFromCli(unheard);

    await openSection(page, 'calls');
    await expect(page.getByTestId('calls-starting')).toHaveCount(0);
    const heard = uniqueId('REOPENED');
    await placeFromCli(heard);

    await expect(callRow(page, heard).first()).toBeVisible();
    await expect(callRow(page, unheard)).toHaveCount(0);
  });
});
