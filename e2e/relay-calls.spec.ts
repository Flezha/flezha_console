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

  test('a diagnosis explains each finding, and the API lists the factory’s channels', async ({
    page,
  }) => {
    await page.getByTestId('diagnose-btn').click();
    await expect(page.getByTestId('diagnose-panel')).toBeVisible();
    await expect(page.getByTestId('diagnose-verdict')).toHaveText(/^\s*(Nothing wrong|Worth a look|A problem)\s*$/);
    const finding = page.locator('[data-testid^="diagnose-finding-diagnose."]').first();
    await expect(finding.getByTestId('runtime-error-reference')).toHaveAttribute(
      'href',
      /\/errors\.html#diagnose$/,
    );

    await openSection(page, 'api');
    const place = page.getByTestId('api-channel-place');
    await expect(place).toContainText('json');
    await expect(place).toContainText('Yes, json');
    await expect(place).toContainText('Places an order');
    await expect(page.getByTestId('api-schema-place')).toBeVisible();

    const audit = page.getByTestId('api-channel-audit');
    await expect(audit).toContainText('text');
    await expect(audit).toContainText('No');
  });

  test('place is called from its schema’s fields, audit takes a line, and raw sends and calls answer', async ({
    page,
  }) => {
    const pair = uniqueId('FIELDS');

    await page.getByTestId('talk-open-btn').click();
    await expect(page.getByTestId('talk-modal')).toBeVisible();

    await page.getByTestId('talk-channel-pick').selectOption('place');
    await page.getByTestId('talk-field-pair').fill(pair);
    await page.getByTestId('talk-field-amount').fill('1.5');
    await page.getByTestId('talk-channel-submit').click();
    const answer = page.getByTestId('talk-answer').first();
    await expect(answer).toContainText('"status": "placed"');
    await expect(answer).toContainText(pair);

    await page.getByTestId('talk-channel-pick').selectOption('audit');
    await expect(page.getByTestId('talk-channel-facts')).toContainText('does not answer');
    await page.getByTestId('talk-json').fill('an audit line');
    await page.getByTestId('talk-channel-submit').click();
    await expect(page.getByTestId('talk-result').first()).toContainText('The relay accepted the input.');

    await page.getByTestId('talk-mode-raw').click();
    await page.getByTestId('talk-payload').fill('a raw audit line');
    await page.getByTestId('talk-channel').fill('audit');
    await page.getByTestId('talk-send-btn').click();
    await expect(page.getByTestId('talk-result').first()).toContainText('Delivered to');

    const raw = uniqueId('RAW');
    await page.getByTestId('talk-payload').fill(JSON.stringify({ pair: raw, amount: 2 }));
    await page.getByTestId('talk-channel').fill('place');
    await page.getByTestId('talk-call-btn').click();

    // The dialog keeps every result, the latest on top.
    await expect(page.getByTestId('talk-answer').first()).toContainText(raw);
    await expect(page.getByTestId('talk-result')).toHaveCount(4);
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
});
