import { test, expect, startRelayCli, stopRelayCli, uniqueId } from './fixtures';

/**
 * A namespace's Home against the dev stack: the headline, the system and
 * namespace tiles, and inspection from a shared link.
 *
 * What each tile says for an arranged fleet — every verdict, the flow before
 * two readings, a breached limit, the fleet figures' cost — is asserted in
 * `test/flezha_ui_web/live/topology_live_test.exs`; what lives here is that
 * the real fleet reaches the tiles and that their links lead on.
 */
test('/ lands on the Home last worked in, whose tiles count the dev stack', async ({ page, live }) => {
  await live('/namespaces/default');
  await page.goto('/');
  await expect(page).toHaveURL(/\/namespaces\/default$/);

  await expect(page.getByTestId('home-headline')).toHaveAttribute('data-condition', /\w+/);
  await expect(page.getByTestId('home-figures')).toContainText(/relays? healthy/);

  // The dev stack runs one controller and a runner serving the seeded relays.
  for (const tile of ['sys-namespaces', 'sys-nodes', 'sys-runners', 'sys-relays', 'ns-relays', 'ns-runners']) {
    await expect(page.getByTestId(`${tile}-value`), tile).toHaveText(/[1-9]/);
  }
  await expect(page.getByTestId('sys-nodes-condition')).toContainText('This console is connected to');
  await expect(page.getByTestId('ns-flow')).toBeVisible();

  await page.getByTestId('ns-relays-all').click();
  await expect(page).toHaveURL(/\/namespaces\/default\/relays$/);
  await expect(page.getByTestId('relays-index-table')).toBeVisible();

  await page.goBack();
  await page.getByTestId('sys-problems').click();
  await expect(page).toHaveURL(/\/problems$/);
});

test('a relay started and stopped from flz reaches the river without a reload', async ({ page, live }) => {
  // Other workers start and stop relays in `default` too, so the counts are
  // asserted in ExUnit; the river names this test's own relay.
  const id = uniqueId('pw_home');
  await live('/namespaces/default');
  const river = page.getByTestId('home-river');

  try {
    await startRelayCli(id, 'store_input');
    await expect(river.locator('li', { hasText: id }).filter({ hasText: 'started from store_input' })).toHaveCount(1);
  } finally {
    await stopRelayCli(id);
  }

  await expect(river.locator('li', { hasText: id }).filter({ hasText: 'stopped' })).toHaveCount(1);
  await expect(page.getByTestId('ns-relays-value')).toHaveText(/[1-9]/);
});

test('a shared link opens a relay inspector on Home, which opens the relay', async ({ page, live }) => {
  // A seeded relay is never stopped, so it stays while this test inspects it.
  await live('/namespaces/default?inspect=relay:testnet_noop');

  await expect(page.getByTestId('inspector-relay')).toBeVisible();
  await expect(page.getByTestId('inspector-sentence')).toBeVisible();

  await page.getByTestId('inspector-close').click();
  await expect(page.getByTestId('inspector-relay')).toHaveCount(0);
  await expect(page).toHaveURL(/\/namespaces\/default$/);

  await page.goBack();
  await expect(page.getByTestId('inspector-relay')).toBeVisible();
  await page.getByTestId('inspector-open').click();
  await expect(page).toHaveURL(/\/namespaces\/default\/relays\/testnet_noop$/);
});

test('the system and namespace tiles stand level, keep their content inside, and lift on hover', async ({
  page,
  live,
}) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await live('/namespaces/default');
  await expect(page.getByTestId('home-namespace-tiles')).toBeVisible();

  const heights = await page.evaluate(() =>
    [...document.querySelectorAll('[data-testid$="-tiles"] .fui-indicator')].map((tile) =>
      Math.round(tile.getBoundingClientRect().height),
    ),
  );
  // They share one minimum height; a tile whose words wrap further at this
  // width may stand a line taller, never more.
  expect(Math.max(...heights) - Math.min(...heights), `tile heights ${heights}`).toBeLessThanOrEqual(16);

  // Nothing a tile holds — a figure, a sparkline, a meter — leaves its box.
  const spilled = () =>
    page.evaluate(() =>
      [...document.querySelectorAll('.fui-indicator')].flatMap((tile) => {
        const box = tile.getBoundingClientRect();
        return [...tile.querySelectorAll('*')]
          .filter((el) => {
            const inner = el.getBoundingClientRect();
            return inner.width > 0 && (inner.right > box.right + 0.5 || inner.left < box.left - 0.5);
          })
          .map((el) => `${tile.getAttribute('data-testid')}: ${el.className}`);
      }),
    );

  expect(await spilled(), 'at 1280px').toEqual([]);
  for (const width of [390, 360]) {
    await page.setViewportSize({ width, height: 844 });
    expect(await spilled(), `at ${width}px`).toEqual([]);
  }

  await page.setViewportSize({ width: 1280, height: 900 });
  const link = page.getByTestId('ns-runners');
  const resting = await link.evaluate((el) => getComputedStyle(el).boxShadow);
  await link.hover();
  await expect.poll(() => link.evaluate((el) => getComputedStyle(el).boxShadow)).not.toBe(resting);
});
