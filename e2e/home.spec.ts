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
test('/ lands on the Home last worked in, whose map draws the seeded relays and inspects in place', async ({
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

  await page.locator('[data-testid^="map-runner-"]').first().click();
  await expect(page.getByTestId('inspector-runner')).toBeVisible();
  await expect(page.getByTestId('inspector-factories')).toContainText('store_input');
  await page.getByTestId('inspector-close').click();
  await expect(page.getByTestId('inspector-runner')).toHaveCount(0);

  // Which seeded relays get a lane of their own depends on what other workers
  // run beside them: four relays of one factory share a stack lane, and a band
  // draws twelve lanes. A seeded relay is never stopped, so the first one drawn
  // stays while this test clicks it.
  const lane = page.locator('[data-testid^="map-lane-testnet_"][aria-label^="Relay testnet_"]').first();
  // "Relay <id>, <state>, <run> · <factory>[, <rate> in]"
  const label = (await lane.getAttribute('aria-label')) ?? '';
  const [name, , sub] = label.split(', ');
  const id = name?.replace(/^Relay /, '');
  const factory = sub?.split(' · ').pop();
  expect(factory, `a seeded relay's lane names its relay and factory: ${label}`).toMatch(/^\w+$/);

  await lane.click();
  await expect(page).toHaveURL(new RegExp(`/namespaces/default\\?inspect=relay(%3A|:)${id}$`));
  await expect(page.getByTestId('inspector-relay')).toBeVisible();
  await expect(page.getByTestId('inspector-sentence')).toContainText(factory!);

  await page.getByTestId('inspector-close').click();
  await expect(page.getByTestId('inspector-relay')).toHaveCount(0);
  await expect(page).toHaveURL(/\/namespaces\/default$/);

  await page.getByTestId(`map-lane-${id}`).click();
  await page.getByTestId('inspector-open').click();
  await expect(page).toHaveURL(new RegExp(`/namespaces/default/relays/${id}$`));
});
