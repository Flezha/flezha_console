import { test, expect, testIds } from './fixtures';

/**
 * A namespace's Home against the dev stack: the headline, the live map of
 * its runners and relays, and inspection in place.
 *
 * The map's drawing — bands, stacks, the lane cap, flow speeds — and what each
 * inspector says are asserted against arranged fleets in
 * `test/flezha_ui_web/live/topology_live_test.exs`; what lives here is that
 * the real fleet reaches it, and that clicking the map moves the address.
 */
test.describe('Home', () => {
  test('/ lands on the Home last worked in, which opens on a headline and draws the seeded relays', async ({
    page,
    live,
  }) => {
    await live('/namespaces/default');
    await page.goto('/');
    await expect(page).toHaveURL(/\/namespaces\/default$/);

    await expect(page.getByTestId('home-headline')).toHaveAttribute('data-condition', /\w+/);
    await expect(page.getByTestId('home-figures')).toContainText(/relays? healthy/);
    await expect(page.getByTestId('namespace-map')).toBeVisible();

    const bands = await testIds(page, 'map-band-');
    expect(bands.length, 'the dev runner draws a band').toBeGreaterThan(0);

    await expect(page.getByTestId('map-lane-testnet_store_1')).toHaveAttribute(
      'aria-label',
      /^Relay testnet_store_1, .*store_input/,
    );
  });

  test('the map inspects in place: a band and a lane open, close and open the relay', async ({
    page,
    live,
  }) => {
    await live('/namespaces/default');

    await page.locator('[data-testid^="map-runner-"]').first().click();
    await expect(page.getByTestId('inspector-runner')).toBeVisible();
    await expect(page.getByTestId('inspector-factories')).toContainText('store_input');
    await page.getByTestId('inspector-close').click();
    await expect(page.getByTestId('inspector-runner')).toHaveCount(0);

    await page.getByTestId('map-lane-testnet_store_1').click();
    await expect(page).toHaveURL(/\/namespaces\/default\?inspect=relay(%3A|:)testnet_store_1$/);
    await expect(page.getByTestId('inspector-relay')).toBeVisible();
    await expect(page.getByTestId('inspector-sentence')).toContainText('store_input');

    await page.getByTestId('inspector-close').click();
    await expect(page.getByTestId('inspector-relay')).toHaveCount(0);
    await expect(page).toHaveURL(/\/namespaces\/default$/);

    await page.getByTestId('map-lane-testnet_store_1').click();
    await page.getByTestId('inspector-open').click();
    await expect(page).toHaveURL(/\/namespaces\/default\/relays\/testnet_store_1$/);
  });
});
