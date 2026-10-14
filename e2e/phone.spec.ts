import { test, expect, openSettings, openStart, type Page } from './fixtures';

/**
 * The console on a phone held in portrait, and once on a tablet: the drawer
 * the rail becomes, the bottom bar, the one-row topbar, tables read as cards,
 * dialogs as sheets, menus kept on screen and targets a finger can hit.
 *
 * Runs only in the `phone` project (390×844, touch). The LiveView suite proves
 * the shell renders each part for its width; what only a browser can prove is
 * which part the width shows, and what a tap does.
 */

const RELAY = '/namespaces/default/relays/testnet_store_1';

const ROUTES = [
  '/namespaces',
  '/relays',
  '/namespaces/default',
  '/namespaces/default/relays',
  '/namespaces/default/plugins',
  '/namespaces/default/schedules',
  RELAY,
  `${RELAY}/listen`,
  `${RELAY}/state`,
  '/plugins',
  '/schedules',
  '/problems',
  '/dlq',
  '/cluster',
  '/controller',
  '/observability',
  '/audit',
  '/users/settings',
  '/users/log-in',
];

const drawer = (page: Page) => page.locator('#shell-nav');

// The account pages are plain controller pages, with no LiveView to join.
const visit = (page: Page, live: (path: string) => Promise<void>, path: string) =>
  path.startsWith('/users/') ? page.goto(path).then(() => undefined) : live(path);

async function openDrawer(page: Page) {
  await page.getByTestId('tabbar-menu').tap();
  await expect(drawer(page)).toBeVisible();
  await expect(page.getByTestId('tabbar-menu')).toHaveAttribute('aria-expanded', 'true');
}

test.describe('The console on a phone', () => {
  test('the topbar is one row, and the bar carries the main destinations', async ({ page, live }) => {
    await live('/namespaces/default/relays');

    const topbar = await page.getByTestId('topbar').boundingBox();
    expect(topbar!.height).toBeLessThanOrEqual(57);

    await expect(drawer(page)).toBeHidden();
    await expect(page.getByTestId('nav-toggle')).toBeHidden();
    await expect(page.getByTestId('help-btn')).toBeHidden();

    const bar = page.getByTestId('tabbar');
    await expect(bar.locator('a:visible, button:visible')).toHaveText(['Home', 'Relays', /Problems/, 'Search', 'Menu']);
    await expect(page.getByTestId('tabbar-relays')).toHaveAttribute('aria-current', 'page');
  });

  test('each place in the bar is reached by a tap', async ({ page, live }) => {
    await live('/cluster');

    for (const [item, url] of [
      ['tabbar-home', /\/namespaces\/default$/],
      ['tabbar-relays', /\/namespaces\/default\/relays$/],
      ['tabbar-problems', /\/problems$/],
    ] as const) {
      await page.getByTestId(item).tap();
      await expect(page).toHaveURL(url);
      await expect(page.getByTestId(item)).toHaveAttribute('aria-current', 'page');
    }
  });

  test('Search opens the palette full screen, and Cancel leaves it', async ({ page, live }) => {
    await live('/cluster');

    await page.getByTestId('tabbar-search').tap();
    const palette = page.getByTestId('command-palette');
    await expect(palette).toBeVisible();
    await expect(page.getByTestId('command-palette-input')).toBeFocused();
    expect((await palette.boundingBox())!.height).toBeGreaterThanOrEqual(844 - 1);

    await page.getByTestId('command-palette-close').tap();
    await expect(palette).toBeHidden();
    await expect(page).toHaveURL(/\/cluster$/);
    await expect(page.getByTestId('tabbar-search')).toBeFocused();
  });

  test('the drawer opens on the current place, holds focus, and stays open across a refresh', async ({
    page,
    live,
  }) => {
    await live('/namespaces/default/relays');
    await openDrawer(page);

    await expect(drawer(page).locator('[aria-current="page"]')).toBeFocused();
    // The page is the scroller on a phone, and holds still behind the drawer.
    expect(await page.evaluate(() => getComputedStyle(document.documentElement).overflowY)).toBe('hidden');

    for (let i = 0; i < 30; i++) {
      await page.keyboard.press('Tab');
      const behind = await page.evaluate(() => !!document.activeElement?.closest('.flz-app-main, .flz-tabbar'));
      expect(behind, `tab ${i + 1} reached the page behind the drawer`).toBe(false);
    }

    // The clock it shows moves on with the screen's refresh.
    const before = await page.getByTestId('liveness-state').textContent();
    await expect(page.getByTestId('liveness-state')).not.toHaveText(before!);
    await expect(drawer(page)).toBeVisible();
  });

  test('the drawer closes by Escape, by a tap beside it and by following a link', async ({ page, live }) => {
    await live('/namespaces/default');

    await openDrawer(page);
    await page.keyboard.press('Escape');
    await expect(drawer(page)).toBeHidden();
    await expect(page.getByTestId('tabbar-menu')).toBeFocused();
    await expect(page.getByTestId('tabbar-menu')).toHaveAttribute('aria-expanded', 'false');

    await openDrawer(page);
    await page.touchscreen.tap(380, 420);
    await expect(drawer(page)).toBeHidden();
    await expect(page).toHaveURL(/\/namespaces\/default$/);

    await openDrawer(page);
    await drawer(page).getByRole('link', { name: 'Cluster' }).tap();
    await expect(page).toHaveURL(/\/cluster$/);
    await expect(drawer(page)).toBeHidden();
  });

  test('the drawer foot names the principal and switches the theme', async ({ page, live }) => {
    await live('/cluster');
    await expect(page.getByTestId('authz-identity')).toBeHidden();
    await expect(page.getByTestId('theme-toggle')).toBeHidden();

    await openDrawer(page);
    await expect(page.getByTestId('drawer-principal')).toBeVisible();

    const html = page.locator('html');
    const theme = await html.getAttribute('data-theme');
    await page.getByTestId('drawer-theme-toggle').tap();
    await expect(html).not.toHaveAttribute('data-theme', theme!);
    await page.getByTestId('drawer-theme-toggle').tap();
    await expect(html).toHaveAttribute('data-theme', theme!);
  });

  test('the account menu opens on screen, and its settings are reached', async ({ page, live }) => {
    await live('/cluster');

    await page.getByTestId('account-menu').tap();
    const panel = page.locator('#account-menu [role="menu"]');
    await expect(panel).toBeVisible();
    const box = (await panel.boundingBox())!;
    expect(box.x).toBeGreaterThanOrEqual(8);
    expect(box.x + box.width).toBeLessThanOrEqual(390 - 8);

    await openSettings(page, () => panel.getByRole('link', { name: 'Settings' }).tap());
  });

  test('a table reads as cards, each value under its column', async ({ page, live }) => {
    await live('/namespaces/default/relays');

    const row = page.locator('[data-testid^="relay-index-row-"]').first();
    const health = row.locator('td[data-label="Health"]');
    await health.scrollIntoViewIfNeeded();
    await expect(health).toBeInViewport();
    const box = (await health.boundingBox())!;
    expect(box.x + box.width).toBeLessThanOrEqual(390);

    const caption = await health.evaluate((el) => getComputedStyle(el, '::before').content);
    expect(caption).toBe('"Health"');
  });

  test('a sheet keeps its title and step controls in view while its list scrolls', async ({ page, live }) => {
    await live('/namespaces/default/relays');
    await openStart(page);

    const sheet = page.getByTestId('start-modal');
    await sheet.locator('[data-testid="factory-choices"]').evaluate((el) => {
      el.scrollTop = el.scrollHeight;
      el.closest('.fui-dialog-body')!.scrollTop = 1e6;
    });

    await expect(sheet.getByRole('heading', { name: 'Start a relay' })).toBeInViewport();
    await expect(page.getByTestId('start-cancel-btn')).toBeInViewport();
    const sheetBox = (await sheet.boundingBox())!;
    expect(sheetBox.y + sheetBox.height).toBeGreaterThanOrEqual(844 - 1);

    await page.getByTestId('start-cancel-btn').tap();
    await expect(sheet).toBeHidden();
  });

  test('a phone on its side gets the sheet too', async ({ page, live }) => {
    await page.setViewportSize({ width: 844, height: 390 });
    await live('/namespaces/default/relays');
    await openStart(page);

    await expect(page.getByTestId('start-modal').getByRole('heading', { name: 'Start a relay' })).toBeInViewport();
    await expect(page.getByTestId('start-cancel-btn')).toBeInViewport();
    await page.getByTestId('start-cancel-btn').tap();
  });

  test('every control a finger meets is at least 44px tall, and no routed screen scrolls sideways', async ({
    page,
    live,
  }) => {
    const scrollsSideways = () =>
      page.evaluate(() => document.documentElement.scrollWidth > document.documentElement.clientWidth);

    for (const path of ROUTES) {
      await page.setViewportSize({ width: 390, height: 844 });
      await visit(page, live, path);

      // A term or an identifier is a target inside a line of text, which keeps
      // the text's height.
      const small = await page.evaluate(() =>
        [
          ...document.querySelectorAll(
            'button:not(.fui-term, .fui-ident), select, input:not([type="hidden"]), textarea, .fui-segment, .fui-btn',
          ),
        ]
          .filter((el) => {
            const box = el.getBoundingClientRect();
            return box.width > 0 && box.height > 0 && box.height < 43.5;
          })
          .map((el) => `${el.tagName.toLowerCase()} ${el.getAttribute('data-testid') ?? el.className} ${Math.round(el.getBoundingClientRect().height)}px`),
      );
      expect.soft(small, `${path} has controls under 44px`).toEqual([]);
      expect.soft(await scrollsSideways(), `${path} scrolls sideways at 390px`).toBe(false);

      await page.setViewportSize({ width: 360, height: 844 });
      expect.soft(await scrollsSideways(), `${path} scrolls sideways at 360px`).toBe(false);
    }
  });
});

test.describe('The console on a tablet', () => {
  test.use({ viewport: { width: 768, height: 1024 } });

  test('the topbar opens the drawer and the palette, and the title keeps its room', async ({ page, live }) => {
    await live('/namespaces/default/relays');

    await expect(page.getByTestId('tabbar')).toBeHidden();
    await expect(drawer(page)).toBeHidden();

    await page.getByTestId('nav-toggle').tap();
    await expect(drawer(page)).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(page.getByTestId('nav-toggle')).toBeFocused();

    await page.getByTestId('search-open').tap();
    await expect(page.getByTestId('command-palette')).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(page.getByTestId('command-palette')).toBeHidden();

    const title = (await page.getByTestId('page-title').boundingBox())!;
    expect(title.width).toBeGreaterThan(240);
  });
});
