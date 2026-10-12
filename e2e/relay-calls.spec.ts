import { test, expect, openSection, uniqueId } from './fixtures';

/**
 * Asking a relay what is wrong with it, reading the API its factory announces,
 * and talking to it, on the seeded `orders` relay: the dev runner's API
 * fixture, whose `place` channel takes a JSON order and answers it, and whose
 * `audit` channel takes a line of text and answers nothing.
 *
 * Nothing here leaves state behind: a send or a call is an input the relay
 * consumes, and `audit` keeps nothing.
 */
test.describe('Talking to a relay', () => {
  test.beforeEach(async ({ live }) => {
    await live('/namespaces/default/relays/orders');
  });

  test('a diagnosis states a verdict and explains each finding', async ({ page }) => {
    await page.getByTestId('diagnose-btn').click();
    await expect(page.getByTestId('diagnose-panel')).toBeVisible();

    await expect(page.getByTestId('diagnose-verdict')).toHaveText(/^\s*(Nothing wrong|Worth a look|A problem)\s*$/);
    const findings = page.locator('[data-testid^="diagnose-finding-diagnose."]');
    await expect(findings.first()).toBeVisible();
    await expect(findings.first().getByTestId('runtime-error-reference')).toHaveAttribute(
      'href',
      /\/errors\.html#diagnose$/,
    );

    // Running it again replaces the answer rather than appending to it.
    const before = await findings.count();
    await page.getByTestId('diagnose-btn').click();
    await expect(findings).toHaveCount(before);
  });

  test('the API lists the factory’s channels, formats and schemas', async ({ page }) => {
    await openSection(page, 'api');

    await expect(
      page.getByTestId('api-channels').locator('[data-testid^="api-channel-"]'),
    ).not.toHaveCount(0);
    const place = page.getByTestId('api-channel-place');
    await expect(place).toContainText('json');
    await expect(place).toContainText('Yes, json');
    await expect(place).toContainText('Places an order');
    await expect(page.getByTestId('api-schema-place')).toBeVisible();

    const audit = page.getByTestId('api-channel-audit');
    await expect(audit).toContainText('text');
    await expect(audit).toContainText('No');
  });

  test('place is called from fields its schema generated, and answers', async ({ page }) => {
    await page.getByTestId('talk-open-btn').click();
    await expect(page.getByTestId('talk-modal')).toBeVisible();

    await page.getByTestId('talk-channel-pick').selectOption('place');
    await page.getByTestId('talk-field-pair').fill('BTC-EUR');
    await page.getByTestId('talk-field-amount').fill('1.5');
    await page.getByTestId('talk-channel-submit').click();

    const answer = page.getByTestId('talk-answer').first();
    await expect(answer).toContainText('"status": "placed"', { timeout: 20_000 });
    await expect(answer).toContainText('BTC-EUR');
  });

  test('a required field left empty is named and nothing is sent', async ({ page }) => {
    await page.getByTestId('talk-open-btn').click();
    await page.getByTestId('talk-channel-pick').selectOption('place');
    await page.getByTestId('talk-field-pair').fill('BTC-EUR');
    await page.getByTestId('talk-channel-submit').click();

    // The field's container holds its label, control, hint and error.
    const amount = page.getByTestId('talk-field-amount').locator('xpath=..');
    await expect(amount.locator('.fui-error')).toContainText('is required');
    await expect(page.getByTestId('talk-result')).toHaveCount(0);
  });

  test('audit accepts a line of text and answers nothing', async ({ page }) => {
    await page.getByTestId('talk-open-btn').click();
    await page.getByTestId('talk-channel-pick').selectOption('audit');
    await expect(page.getByTestId('talk-channel-facts')).toContainText('does not answer');

    await page.getByTestId('talk-json').fill('an audit line');
    await page.getByTestId('talk-channel-submit').click();

    await expect(page.getByTestId('talk-result').first()).toContainText(
      'The relay accepted the input.',
      { timeout: 20_000 },
    );
  });

  test('a raw message is sent and a raw call answered', async ({ page }) => {
    await page.getByTestId('talk-open-btn').click();
    await page.getByTestId('talk-mode-raw').click();

    await page.getByTestId('talk-payload').fill('a raw audit line');
    await page.getByTestId('talk-channel').fill('audit');
    await page.getByTestId('talk-send-btn').click();
    await expect(page.getByTestId('talk-result').first()).toContainText('Delivered to', {
      timeout: 20_000,
    });

    await page.getByTestId('talk-payload').fill('{"pair":"ETH-EUR","amount":2}');
    await page.getByTestId('talk-channel').fill('place');
    await page.getByTestId('talk-deadline').fill('20000');
    await page.getByTestId('talk-call-btn').click();

    // The dialog keeps both, the call's answer on top.
    await expect(page.getByTestId('talk-answer').first()).toContainText('ETH-EUR', {
      timeout: 25_000,
    });
    await expect(page.getByTestId('talk-result')).toHaveCount(2);
    await expect(page.getByTestId('talk-result').nth(1)).toContainText('Delivered to');
  });

  test('closing the dialog while a call waits stops waiting and keeps no result for it', async ({
    page,
  }) => {
    await page.getByTestId('talk-open-btn').click();
    await page.getByTestId('talk-mode-raw').click();
    await expect(page.getByTestId('talk-raw-form')).toBeVisible();

    // `audit` answers nothing, so the call waits out its deadline.
    await page.getByTestId('talk-raw-form').getByTestId('talk-payload').fill(uniqueId('waited'));
    await page.getByTestId('talk-channel').fill('audit');
    await page.getByTestId('talk-deadline').fill('20000');
    await page.getByTestId('talk-call-btn').click();
    await expect(page.getByTestId('talk-waiting')).toBeVisible();
    await expect(page.getByTestId('talk-call-btn')).toBeDisabled();

    await page.getByTestId('talk-close-btn').click();
    await expect(page.getByTestId('talk-modal')).toHaveCount(0);

    await page.getByTestId('talk-open-btn').click();
    await expect(page.getByTestId('talk-waiting')).toHaveCount(0);
    await expect(page.getByTestId('talk-result')).toHaveCount(0);

    // Back to the channel form, which is where the dialog opens.
    await page.getByTestId('talk-mode-raw').click();
    await expect(page.getByTestId('talk-call-btn')).toBeEnabled();
    await page.getByTestId('talk-mode-channel').click();
    await page
      .getByTestId('talk-channel-form')
      .getByTestId('talk-channel-pick')
      .selectOption('place');
    await expect(page.getByTestId('talk-raw-form')).toHaveCount(0);
  });

  test('closing the dialog leaves the screen working', async ({ page }) => {
    await page.getByTestId('talk-open-btn').click();
    await page.getByTestId('talk-close-btn').click();

    await expect(page.getByTestId('talk-modal')).toHaveCount(0);
    await page.getByTestId('diagnose-btn').click();
    await expect(page.getByTestId('diagnose-verdict')).toBeVisible();
  });
});
