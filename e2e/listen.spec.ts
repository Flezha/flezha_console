import { test, expect } from './fixtures';

/**
 * The listen screen for a running relay.
 *
 * `testnet_store_1` is seeded by the dev setup, so the listen has a real relay
 * to attach to. The screen's error state — the controller refusing the
 * listen — is covered in `test/flezha_ui_web/live/listen_live_test.exs`.
 */
const LISTEN_URL = '/namespaces/default/relays/testnet_store_1/listen';

test.describe('Listen', () => {
  test.beforeEach(async ({ live }) => {
    await live(LISTEN_URL);
  });

  test('attaches a listener to the relay', async ({ page }) => {
    await expect(
      page.getByTestId('listen-error'),
      'the listen must be accepted by the controller',
    ).toHaveCount(0);

    await expect(page.getByTestId('listen-connecting')).toHaveCount(0);
    await expect(page.getByTestId('listen-feed')).toBeVisible();
    await expect(page.getByTestId('listen-count')).toContainText('messages received');
  });

  test('switches between listening to inputs and outputs', async ({ page }) => {
    await page.getByTestId('listen-direction-input').click();
    await expect(page.getByTestId('listen-direction-input')).toHaveAttribute('aria-pressed', 'true');
    await expect(page.getByTestId('listen-feed')).toContainText('input');

    await page.getByTestId('listen-direction-output').click();
    await expect(page.getByTestId('listen-direction-output')).toHaveAttribute(
      'aria-pressed',
      'true',
    );
    await expect(page.getByTestId('listen-feed')).toContainText('output');
  });

  test('pauses and resumes', async ({ page }) => {
    const pause = page.getByTestId('listen-pause');
    await expect(pause).toContainText('Pause');

    await pause.click();
    await expect(pause).toContainText('Resume');
    await expect(page.getByTestId('listen-count')).toContainText('(paused)');

    await pause.click();
    await expect(pause).toContainText('Pause');
    await expect(page.getByTestId('listen-count')).not.toContainText('(paused)');
  });

  test('filters and clears', async ({ page }) => {
    await page.getByTestId('listen-filter').fill('no_message_matches_this');
    await expect(page.getByTestId('listen-filter')).toHaveValue('no_message_matches_this');

    await page.getByTestId('listen-clear').click();
    await expect(page.getByTestId('listen-count')).toContainText('0 messages received');
  });

  test('navigates back to the relay', async ({ page }) => {
    await page.getByTestId('relay-tab-detail').click();
    await expect(page).toHaveURL(/\/namespaces\/default\/relays\/testnet_store_1$/);
  });
});
