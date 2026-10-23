import {
  test,
  expect,
  closeSection,
  openPalette,
  openSection,
  timelineSamples,
  openPage,
  type Page,
} from './fixtures';

/**
 * The shell, in a browser: the rail, the picker, the crumb trail, the tabs on
 * a relay, the palette's keyboard, a section remembering it was folded, and a
 * screen's own refresh.
 *
 * The LiveView suite proves the server renders these, including which rail
 * entry is marked and how the scope reads. What only a browser can prove is
 * that the keyboard reaches the palette, that a tab or a crumb navigates to its
 * own route, that a fold survives a reload, and that a tick lands on its own —
 * all of which live in the client or the socket.
 */

const RELAY = '/namespaces/default/relays/testnet_store_1';

/** When the screen last refreshed, as its liveness states it. */
async function lastRefresh(page: Page): Promise<string | undefined> {
  return (await page.getByTestId('liveness-state').textContent())?.match(/\d\d:\d\d:\d\d\.\d{3}/)?.[0];
}

test.describe('The console shell', () => {
  test('every rail entry reaches its own screen and is marked there', async ({ page, live }) => {
    await live('/namespaces/default');
    const rail = page.locator('.flz-sidebar-nav');
    const hrefs = await rail.locator('a.flz-sidebar-link').evaluateAll((links) =>
      links.map((a) => a.getAttribute('href')!),
    );
    expect(hrefs.length).toBeGreaterThan(8);

    for (const href of hrefs) {
      await rail.locator(`a.flz-sidebar-link[href="${href}"]`).click();
      await expect(page).toHaveURL((url) => url.pathname === href);
      await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-loading/);
      await expect(rail.locator(`a.flz-sidebar-link[href="${href}"]`)).toHaveAttribute('aria-current', 'page');
      await expect(page.locator('h1').first()).not.toBeEmpty();
    }
  });

  test('the picker names the scope and keeps the screen kind', async ({ page, live }) => {
    await live('/namespaces/default/plugins');

    const picker = page.getByTestId('namespace-picker');
    await expect(picker).toContainText('default');

    await picker.click();
    await page.getByTestId('namespace-picker-default').click();

    await expect(page).toHaveURL(/\/namespaces\/default\/plugins$/);
  });

  test('the account controls are one menu, and the theme toggle is always in the topbar', async ({
    page,
    live,
  }) => {
    await live('/cluster');

    await expect(page.locator('.flz-topbar [data-testid="theme-toggle"]')).toBeVisible();
    // Nothing to log out with until the menu is opened.
    await expect(page.getByTestId('log-out')).toBeHidden();

    await page.getByTestId('account-menu').click();

    await expect(page.getByTestId('account-identity')).toBeVisible();
    await expect(page.getByTestId('log-out')).toBeVisible();
    await expect(page.locator('#account-menu [data-flz-theme-toggle]')).toHaveCount(0);
  });

  test('a lost connection says so in one toast row: icon, words, dismiss', async ({ page, live, pageHealth }) => {
    pageHealth.allow(/took phx-(client-)?error/, 'the test drops the socket on purpose');
    await live('/cluster');

    await page.evaluate(() =>
      (window as unknown as { liveSocket: { disconnect(): void } }).liveSocket.disconnect(),
    );

    const toast = page.locator('#client-error');
    await expect(toast).toBeVisible();
    await expect(toast).toHaveCSS('display', 'flex');
    const icon = (await toast.locator('.fui-toast-icon').boundingBox())!;
    const dismiss = (await toast.locator('[data-toast-dismiss]').boundingBox())!;
    expect(dismiss.y).toBeLessThan(icon.y + icon.height);
    expect(dismiss.x).toBeGreaterThan(icon.x + icon.width);
  });
});

test.describe("A relay's views", () => {
  test('are a tab strip that navigates between three routes, under crumbs that navigate', async ({
    page,
    live,
  }) => {
    await live(RELAY);

    const tabs = page.getByRole('navigation', { name: 'Relay views' });
    await expect(tabs).toBeVisible();
    await expect(page.getByTestId('relay-tab-live')).toHaveAttribute('aria-current', 'page');

    await page.getByTestId('relay-tab-listen').click();
    await expect(page).toHaveURL(new RegExp(`${RELAY}/listen$`));
    await expect(page.getByTestId('relay-tab-listen')).toHaveAttribute('aria-current', 'page');
    await expect(page.getByTestId('breadcrumb').locator('[aria-current="page"]')).toHaveText(
      'Listen',
    );

    await page.getByTestId('relay-tab-state').click();
    await expect(page).toHaveURL(new RegExp(`${RELAY}/state$`));
    await expect(page.getByTestId('relay-tab-state')).toHaveAttribute('aria-current', 'page');

    await page.getByTestId('relay-tab-live').click();
    await expect(page).toHaveURL(new RegExp(`${RELAY}$`));

    // The current view is the last crumb, marked and not a link; its
    // ancestors are links to their own screens.
    await page.getByTestId('relay-tab-state').click();
    const trail = page.getByTestId('breadcrumb');
    await expect(trail.locator('[aria-current="page"]')).toHaveText('State');
    await trail.locator(`a[href="${RELAY}"]`).click();
    await expect(page).toHaveURL((url) => url.pathname === RELAY);
    await page.getByTestId('breadcrumb').locator('a[href="/namespaces/default/relays"]').click();
    await expect(page).toHaveURL((url) => url.pathname === '/namespaces/default/relays');
  });
});

test.describe('Folded sections', () => {
  test('open on a click and stay folded across a reload', async ({ page, live }) => {
    await live(RELAY);

    // Declared closed, so the screen opens on the graph and the facts.
    await expect(page.getByTestId('section-body-plugins')).toHaveCount(0);
    await expect(page.getByTestId('section-toggle-plugins')).toHaveAttribute(
      'aria-expanded',
      'false',
    );

    await openSection(page, 'plugins');

    await live(RELAY);
    await expect(page.getByTestId('section-body-plugins')).toBeVisible();

    await closeSection(page, 'plugins');

    await live(RELAY);
    await expect(page.getByTestId('section-body-plugins')).toHaveCount(0);
  });
});

test.describe('A browser that refuses to store the preference', () => {
  test('leaves the screen on its declared defaults', async ({ page, live }) => {
    // Some browsers throw on access in a private window rather than merely
    // answering nothing, so the hook has to survive the throw, not the null.
    // Refused for the fold's own keys alone: LiveView stores its socket state
    // here too, and a page whose socket cannot connect proves nothing.
    await page.addInitScript(() => {
      const storage = window.localStorage;
      const refuse = (key: string) => {
        if (key.startsWith('flz-section:')) {
          throw new DOMException('storage is disabled', 'SecurityError');
        }
      };
      Object.defineProperty(window, 'localStorage', {
        configurable: true,
        get: () => ({
          getItem: (key: string) => (refuse(key), storage.getItem(key)),
          setItem: (key: string, value: string) => (refuse(key), storage.setItem(key, value)),
          removeItem: (key: string) => (refuse(key), storage.removeItem(key)),
        }),
      });
    });

    await live(RELAY);

    // Declared closed, and openable — not failed, and not stuck shut.
    await expect(page.getByTestId('section-body-plugins')).toHaveCount(0);
    await openSection(page, 'plugins');

    await live(RELAY);
    await expect(page.getByTestId('section-body-plugins')).toHaveCount(0);
  });
});

test.describe('The command palette', () => {
  test('closes on Escape and a click outside, says when nothing matches, reaches a relay and a screen, and leaves a field its shortcut', async ({
    page,
    live,
  }) => {
    await live('/audit');

    await openPalette(page);
    await page.getByTestId('command-palette-search').getByTestId('command-palette-input').fill('dead');
    await page.keyboard.press('Escape');
    await expect(page.getByTestId('command-palette')).toHaveCount(0);

    await openPalette(page);
    await page.mouse.click(5, 5);
    await expect(page.getByTestId('command-palette')).toHaveCount(0);
    await expect(page).toHaveURL(/\/audit$/);

    await openPalette(page);
    await page.getByTestId('command-palette-input').fill('nothing-is-called-this');
    await expect(page.getByTestId('command-palette-empty')).toBeVisible();

    await page.getByTestId('command-palette-input').fill('testnet_store_1');

    await expect(page.getByTestId('command-palette-results')).toContainText('testnet_store_1');
    const match = page.getByTestId('command-palette-relay-testnet_store_1');
    await expect(match).toBeVisible();
    await expect(match).toContainText('default');

    await match.click();
    await expect(page).toHaveURL(new RegExp(`${RELAY}$`));

    await openPalette(page);
    await page.getByTestId('command-palette-input').fill('dead');
    await page.getByTestId('command-palette-screen-Dead-letter').click();
    await expect(page).toHaveURL(/\/dlq$/);

    await page.getByTestId('dlq-filter').click();
    await page.keyboard.press('Control+k');

    await expect(page.getByTestId('command-palette')).toHaveCount(0);
  });
});

test.describe('A screen that refreshes', () => {
  test('ticks on its own, and holds its figures still while paused', async ({ page, live }) => {
    await live(RELAY);

    const state = page.getByTestId('liveness-state');
    await expect(state).toContainText('Every');
    const first = await lastRefresh(page);
    await expect.poll(() => lastRefresh(page), { message: 'the screen never refreshed' }).not.toBe(first);

    await page.getByTestId('liveness-toggle').click();
    await expect(state).toContainText('Paused');
    const held = await timelineSamples(page);

    // A second copy of the screen keeps refreshing; once it has ticked twice,
    // the paused one has missed at least one tick it would have taken.
    const other = await openPage(page, RELAY);
    for (const tick of ['once', 'twice']) {
      const before = await lastRefresh(other);
      await expect.poll(() => lastRefresh(other), { message: `the other copy did not tick ${tick}` }).not.toBe(before);
    }
    await other.close();

    expect(await timelineSamples(page)).toBe(held);
    await page.getByTestId('liveness-toggle').click();
    await expect(state).toContainText('Every');
    await expect.poll(() => timelineSamples(page), { message: 'the resumed timeline' }).toBeGreaterThan(held);
  });
});
