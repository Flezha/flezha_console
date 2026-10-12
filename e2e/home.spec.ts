import { test, expect, testIds, visitLive } from './fixtures';

/**
 * A namespace's Home against the dev stack: the headline, the live map of
 * its runners and relays, and inspection in place.
 *
 * The map's drawing — bands, stacks, the lane cap, flow speeds — is asserted
 * against arranged fleets in `test/flezha_ui_web/live/topology_live_test.exs`;
 * what lives here is that the real fleet reaches it.
 */
test.describe('Home', () => {
  test.beforeEach(async ({ live }) => {
    await live('/namespaces/default');
  });

  test('opens on a headline and the figures behind it', async ({ page }) => {
    await expect(page.getByTestId('home-headline')).toHaveAttribute('data-condition', /\w+/);
    await expect(page.getByTestId('home-figures')).toContainText(/relays? healthy/);
  });

  test('draws the seeded relays as lanes in their runner’s band', async ({ page }) => {
    await expect(page.getByTestId('namespace-map')).toBeVisible();

    const bands = await testIds(page, 'map-band-');
    expect(bands.length, 'the dev runner draws a band').toBeGreaterThan(0);

    const lane = page.getByTestId('map-lane-testnet_store_1');
    await expect(lane).toHaveAttribute('aria-label', /^Relay testnet_store_1, .*store_input/);
  });

  test('a lane opens the relay inspector in place, and it opens the relay', async ({ page }) => {
    await page.getByTestId('map-lane-testnet_store_1').click();

    await expect(page).toHaveURL(/\/namespaces\/default\?inspect=relay(%3A|:)testnet_store_1$/);
    await expect(page.getByTestId('inspector-relay')).toBeVisible();
    await expect(page.getByTestId('inspector-sentence')).toContainText('store_input');

    await page.getByTestId('inspector-open').click();
    await expect(page).toHaveURL(/\/namespaces\/default\/relays\/testnet_store_1$/);
  });

  test('a runner’s band opens what it serves', async ({ page }) => {
    await page.locator('[data-testid^="map-runner-"]').first().click();

    await expect(page.getByTestId('inspector-runner')).toBeVisible();
    await expect(page.getByTestId('inspector-factories')).toContainText('store_input');
  });

  test('closing the inspector clears the address', async ({ page }) => {
    await page.getByTestId('map-lane-testnet_store_1').click();
    await expect(page.getByTestId('inspector-relay')).toBeVisible();

    await page.getByTestId('inspector-close').click();
    await expect(page.getByTestId('inspector-relay')).toHaveCount(0);
    await expect(page).toHaveURL(/\/namespaces\/default$/);
  });
});

test.describe('Landing', () => {
  test('/ opens the Home of the namespace last worked in', async ({ page }) => {
    await visitLive(page, '/namespaces/default');
    await page.goto('/');

    await expect(page).toHaveURL(/\/namespaces\/default$/);
    await expect(page.getByTestId('namespace-map')).toBeVisible();
  });
});
