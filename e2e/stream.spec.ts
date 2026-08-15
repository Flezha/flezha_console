import { test, expect } from './fixtures';

/**
 * The stream screen for a running operative.
 *
 * `testnet_store_1` is seeded by the dev setup, so the stream has a real
 * operative to attach to. The screen's error state — the controller refusing
 * the listener — is covered in
 * `test/flezha_ui_web/live/stream_live_test.exs`.
 */
const STREAM_URL = '/namespaces/default/operatives/testnet_store_1/stream';

test.describe('Stream', () => {
  test.beforeEach(async ({ live }) => {
    await live(STREAM_URL);
  });

  test('connects to the operative stream', async ({ page }) => {
    await expect(
      page.getByTestId('stream-error'),
      'the stream listener must be accepted by the controller',
    ).toHaveCount(0);

    await expect(page.getByTestId('stream-feed')).toBeVisible();
    await expect(page.getByTestId('stream-count')).toContainText('messages received');
  });

  test('switches between the input and output streams', async ({ page }) => {
    await page.getByTestId('stream-io-input').click();
    await expect(page.getByTestId('stream-feed')).toContainText('input');

    await page.getByTestId('stream-io-output').click();
    await expect(page.getByTestId('stream-feed')).toContainText('output');
  });

  test('pauses and resumes', async ({ page }) => {
    const pause = page.getByTestId('stream-pause');
    await expect(pause).toContainText('Pause');

    await pause.click();
    await expect(pause).toContainText('Resume');
    await expect(page.getByTestId('stream-count')).toContainText('(paused)');

    await pause.click();
    await expect(pause).toContainText('Pause');
    await expect(page.getByTestId('stream-count')).not.toContainText('(paused)');
  });

  test('filters and clears', async ({ page }) => {
    await page.getByTestId('stream-filter').fill('no_message_matches_this');
    await expect(page.getByTestId('stream-filter')).toHaveValue('no_message_matches_this');

    await page.getByTestId('stream-clear').click();
    await expect(page.getByTestId('stream-count')).toContainText('0 messages received');
  });

  test('navigates back to the operative', async ({ page }) => {
    await page.locator('a[href$="/namespaces/default/operatives/testnet_store_1"]').first().click();
    await expect(page).toHaveURL(/\/namespaces\/default\/operatives\/testnet_store_1$/);
  });
});
