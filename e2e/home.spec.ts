import { test, expect, startRelayCli, stopRelayCli, uniqueId } from './fixtures';

/**
 * A namespace's Home against the dev stack: the headline, the namespace
 * tiles, and inspection from a shared link.
 *
 * What each tile says for an arranged fleet — every verdict, the flow before
 * two readings, a breached limit — is asserted in
 * `test/flezha_console_web/live/topology_live_test.exs`; what lives here is that
 * the real fleet reaches the tiles and that their links lead on.
 */
test('/ lands on the Home last worked in, whose tiles count the dev stack', async ({ page, live }) => {
  await live('/namespaces/default');
  await page.goto('/');
  await expect(page).toHaveURL(/\/namespaces\/default$/);

  await expect(page.getByTestId('home-headline')).toHaveAttribute('data-condition', /\w+/);
  await expect(page.getByTestId('home-figures')).toContainText(/relays? healthy/);

  // The real fleet reaches each tile; how large it is is the stack's to say,
  // so each figure is read for its form.
  for (const tile of ['ns-relays', 'ns-runners']) {
    await expect(page.getByTestId(`${tile}-value`), tile).toHaveText(/\d/);
  }
  await expect(page.getByTestId('ns-flow')).toBeVisible();
  // Figures for the whole cluster are the Cluster screen's.
  await expect(page.locator('[data-testid^="sys-"]')).toHaveCount(0);

  await page.getByTestId('ns-relays-all').click();
  await expect(page).toHaveURL(/\/namespaces\/default\/relays$/);
  await expect(page.getByTestId('relays-index-table')).toBeVisible();
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
  await expect(page.getByTestId('ns-relays-value')).toHaveText(/\d/);
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

test('the namespace tiles stand level, keep their content inside, and lift on hover', async ({
  page,
  live,
}) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await live('/namespaces/default');
  await expect(page.getByTestId('home-namespace-tiles')).toBeVisible();

  // Each row of tiles is a grid line with one minimum height; a line grows
  // only as far as its most wrapped tile needs, which is the stack's to
  // decide, so tiles are compared within their line, never across lines.
  const lines = await page.evaluate(() => {
    const byLine = new Map<string, { minimum: number; heights: number[] }>();
    for (const tile of document.querySelectorAll('[data-testid$="-tiles"] .fcon-indicator')) {
      const grid = tile.closest('[data-testid$="-tiles"]') as HTMLElement;
      const box = tile.getBoundingClientRect();
      const key = `${grid.dataset.testid} at ${Math.round(box.top)}`;
      const minimum = parseFloat(getComputedStyle(grid).gridAutoRows.replace(/^minmax\(/, ''));
      const line = byLine.get(key) ?? { minimum, heights: [] };
      line.heights.push(Math.round(box.height));
      byLine.set(key, line);
    }
    return [...byLine.entries()];
  });

  expect(lines.length).toBeGreaterThanOrEqual(1);
  for (const [line, { minimum, heights }] of lines) {
    expect(Math.min(...heights), `${line}: ${heights}`).toBeGreaterThanOrEqual(minimum);
    expect(Math.max(...heights) - Math.min(...heights), `${line}: ${heights}`).toBeLessThanOrEqual(16);
  }

  // Nothing a tile holds — a figure, a sparkline, a meter — leaves its box.
  const spilled = () =>
    page.evaluate(() =>
      [...document.querySelectorAll('.fcon-indicator')].flatMap((tile) => {
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
