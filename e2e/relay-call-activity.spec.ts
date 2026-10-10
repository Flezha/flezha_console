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

function placeFromCli(pair: string): unknown {
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

  test('a call from the terminal shows its source, channel, answer and duration', async ({
    page,
  }) => {
    await openCalls(page);
    const pair = uniqueId('CLI');

    expect(placeFromCli(pair)).toMatchObject({ answer: { status: 'placed', pair } });

    const row = callRow(page, pair).first();
    await expect(row.locator('[data-testid^="call-source-"]')).toHaveText('CLI');
    await expect(row).toContainText('place');
    await expect(row.locator('[data-testid^="call-outcome-"]')).toHaveText('answered', {
      timeout: 20_000,
    });
    await expect(row).toContainText('"status":"placed"');
    await expect(row).toContainText(/\d+(ms|s)\b/);
  });

  test('a call from the dialog is a UI call, and the dialog keeps its results', async ({
    page,
  }) => {
    await openCalls(page);
    const pairs = [uniqueId('UIA'), uniqueId('UIB')];

    await page.getByTestId('talk-open-btn').click();
    await page.getByTestId('talk-channel-pick').selectOption('place');

    for (const [index, pair] of pairs.entries()) {
      await page.getByTestId('talk-field-pair').fill(pair);
      await page.getByTestId('talk-field-amount').fill('1');
      await page.getByTestId('talk-channel-submit').click();
      await expect(page.getByTestId('talk-result')).toHaveCount(index + 1, { timeout: 20_000 });
    }

    await page.getByTestId('talk-close-btn').click();
    await page.getByTestId('talk-open-btn').click();
    await expect(page.getByTestId('talk-result')).toHaveCount(2);
    await expect(page.getByTestId('talk-answer').first()).toContainText(pairs[1]);
    await page.getByTestId('talk-close-btn').click();

    for (const pair of pairs) {
      const row = callRow(page, pair).first();
      await expect(row.locator('[data-testid^="call-source-"]')).toHaveText('UI');
      await expect(row.locator('[data-testid^="call-outcome-"]')).toHaveText('answered');
    }
  });

  test('a call nobody answers in time shows as timed out', async ({ page }) => {
    await openCalls(page);
    const line = uniqueId('unanswered');

    await page.getByTestId('talk-open-btn').click();
    await page.getByTestId('talk-mode-raw').click();
    await page.getByTestId('talk-payload').fill(line);
    await page.getByTestId('talk-channel').fill('audit');
    await page.getByTestId('talk-deadline').fill('500');
    await page.getByTestId('talk-call-btn').click();
    await expect(page.getByTestId('talk-result').first()).toContainText('call.timeout', {
      timeout: 20_000,
    });
    await page.getByTestId('talk-close-btn').click();

    const row = callRow(page, line).first();
    await expect(row.locator('[data-testid^="call-outcome-"]')).toHaveText('timed out', {
      timeout: 20_000,
    });
    await expect(row).toContainText('call.timeout');
  });

  test('a folded panel listens to nothing', async ({ page }) => {
    await openCalls(page);
    await closeSection(page, 'calls');

    const unheard = uniqueId('FOLDED');
    placeFromCli(unheard);

    await openSection(page, 'calls');
    await expect(page.getByTestId('calls-starting')).toHaveCount(0);
    const heard = uniqueId('REOPENED');
    placeFromCli(heard);

    await expect(callRow(page, heard).first()).toBeVisible();
    await expect(callRow(page, unheard)).toHaveCount(0);
  });
});
