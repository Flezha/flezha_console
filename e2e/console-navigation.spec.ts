import { test, expect, closeSection, openPalette, openSection } from './fixtures';

/**
 * The shell, in a browser: the two-section rail, the scope in the route, the
 * crumb trail, the tabs on an operative, the palette's keyboard, and a section
 * remembering it was folded.
 *
 * The LiveView suite proves the server renders these. What only a browser can
 * prove is that the keyboard reaches the palette, that a tab navigates to its
 * own route, and that a fold survives a reload — all of which live in the
 * client.
 */

const OPERATIVE = '/namespaces/default/operatives/testnet_store_1';

test.describe('The console shell', () => {
  test('the rail separates namespace-scoped screens from platform ones', async ({ page, live }) => {
    await live('/');

    const rail = page.locator('.flz-sidebar-nav');
    await expect(rail.locator('.flz-sidebar-section')).toHaveCount(2);

    // Nothing is scoped from the dashboard, so the rail says so instead of
    // offering four destinations with no namespace to point at.
    await expect(page.getByTestId('no-namespace-scoped')).toBeVisible();
    await expect(rail.locator('a[href="/operatives"]')).toContainText('Fleet');

    await live('/namespaces/default');

    await expect(page.getByTestId('no-namespace-scoped')).toHaveCount(0);
    await expect(rail.locator('a[href="/namespaces/default/operatives"]')).toBeVisible();
    await expect(rail.locator('a[href="/namespaces/default/plugins"]')).toBeVisible();
    await expect(rail.locator('a[href="/namespaces/default/schedules"]')).toBeVisible();
  });

  test('a scoped route marks its own entry and not the platform twin', async ({ page, live }) => {
    await live('/namespaces/default/operatives');

    const rail = page.locator('.flz-sidebar-nav');
    await expect(rail.locator('[aria-current="page"]')).toHaveCount(1);
    await expect(rail.locator('a[href="/namespaces/default/operatives"]')).toHaveAttribute(
      'aria-current',
      'page',
    );
  });

  test('the picker names the scope and keeps the screen kind', async ({ page, live }) => {
    await live('/namespaces/default/plugins');

    const picker = page.getByTestId('namespace-picker');
    await expect(picker).toContainText('default');

    await picker.click();
    await page.getByTestId('namespace-picker-default').click();

    await expect(page).toHaveURL(/\/namespaces\/default\/plugins$/);
  });

  test('a deep screen names its ancestors and they navigate', async ({ page, live }) => {
    await live(`${OPERATIVE}/state`);

    const trail = page.getByTestId('breadcrumb');
    await expect(trail).toBeVisible();
    await expect(trail).toContainText('default');
    await expect(trail).toContainText('testnet_store_1');

    // The current view is the last crumb, marked and not a link.
    await expect(trail.locator('[aria-current="page"]')).toHaveText('State');

    await trail.locator('a[href="/namespaces/default"]').click();
    await expect(page).toHaveURL(/\/namespaces\/default$/);

    // A top-level screen has no trail to render.
    await live('/');
    await expect(page.getByTestId('breadcrumb')).toHaveCount(0);
  });

  test('the account controls are one menu, log out included', async ({ page, live }) => {
    await live('/');

    // Nothing to log out with until the menu is opened.
    await expect(page.getByTestId('log-out')).toBeHidden();

    await page.getByTestId('account-menu').click();

    await expect(page.getByTestId('account-identity')).toBeVisible();
    await expect(page.getByTestId('log-out')).toBeVisible();
    await expect(page.locator('[data-flz-theme-toggle]')).toBeVisible();
  });
});

test.describe("An operative's views", () => {
  test('are a tab strip that navigates between three routes', async ({ page, live }) => {
    await live(OPERATIVE);

    const tabs = page.getByTestId('operative-tabs');
    await expect(tabs).toBeVisible();
    await expect(page.getByTestId('operative-tab-detail')).toHaveAttribute('aria-current', 'page');

    await page.getByTestId('operative-tab-stream').click();
    await expect(page).toHaveURL(new RegExp(`${OPERATIVE}/stream$`));
    await expect(page.getByTestId('operative-tab-stream')).toHaveAttribute('aria-current', 'page');

    await page.getByTestId('operative-tab-state').click();
    await expect(page).toHaveURL(new RegExp(`${OPERATIVE}/state$`));
    await expect(page.getByTestId('operative-tab-state')).toHaveAttribute('aria-current', 'page');

    await page.getByTestId('operative-tab-detail').click();
    await expect(page).toHaveURL(new RegExp(`${OPERATIVE}$`));
  });
});

test.describe('Folded sections', () => {
  test('open on a click and stay folded across a reload', async ({ page, live }) => {
    await live(OPERATIVE);

    // Declared closed, so the screen opens on the graph and the facts.
    await expect(page.getByTestId('section-body-plugins')).toHaveCount(0);
    await expect(page.getByTestId('section-toggle-plugins')).toHaveAttribute(
      'aria-expanded',
      'false',
    );

    await openSection(page, 'plugins');

    await live(OPERATIVE);
    await expect(page.getByTestId('section-body-plugins')).toBeVisible();

    await closeSection(page, 'plugins');

    await live(OPERATIVE);
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

    await live(OPERATIVE);

    // Declared closed, and openable — not failed, and not stuck shut.
    await expect(page.getByTestId('section-body-plugins')).toHaveCount(0);
    await openSection(page, 'plugins');

    await live(OPERATIVE);
    await expect(page.getByTestId('section-body-plugins')).toHaveCount(0);
  });
});

test.describe('The command palette', () => {
  test('opens on the shortcut and reaches an operative by id', async ({ page, live }) => {
    await live('/audit');

    await openPalette(page);
    await page.getByTestId('command-palette-input').fill('testnet_store_1');

    const match = page.getByTestId('command-palette-operative-testnet_store_1');
    await expect(match).toBeVisible();
    await expect(match).toContainText('default');

    await match.click();
    await expect(page).toHaveURL(new RegExp(`${OPERATIVE}$`));
  });

  test('reaches a screen by name, and says when nothing matches', async ({ page, live }) => {
    await live('/audit');

    await openPalette(page);
    await page.getByTestId('command-palette-input').fill('nothing-is-called-this');
    await expect(page.getByTestId('command-palette-empty')).toBeVisible();

    await page.getByTestId('command-palette-input').fill('dead');
    await page.getByTestId('command-palette-screen-Dead-letter').click();

    await expect(page).toHaveURL(/\/dlq$/);
  });

  test('does not steal the shortcut from a field being typed into', async ({ page, live }) => {
    await live('/dlq');

    await page.getByTestId('dlq-filter').click();
    await page.keyboard.press('Control+k');

    await expect(page.getByTestId('command-palette')).toHaveCount(0);
  });
});

test.describe('A screen that refreshes', () => {
  test('states its liveness and can be held still', async ({ page, live }) => {
    await live('/operatives');

    const state = page.getByTestId('liveness-state');
    await expect(state).toContainText('Every 5s');

    await page.getByTestId('liveness-toggle').click();
    await expect(state).toContainText('Paused');

    await page.getByTestId('liveness-toggle').click();
    await expect(state).toContainText('Every 5s');
  });
});

test.describe('Fleet filters', () => {
  test('are written to the query string and reversed by the back button', async ({
    page,
    live,
  }) => {
    await live('/operatives');

    await page.getByTestId('filter-health').click();
    await page.getByTestId('filter-health-suspended').click();

    await expect(page).toHaveURL(/\?.*health=suspended/);
    await expect(page.getByTestId('operative-index-row-testnet_chat')).toBeVisible();
    await expect(page.getByTestId('operative-index-row-testnet_store_1')).toHaveCount(0);

    await page.goBack();

    await expect(page).not.toHaveURL(/health=suspended/);
    await expect(page.getByTestId('operative-index-row-testnet_store_1')).toBeVisible();
  });

  test('a scoped listing keeps its namespace out of the query string', async ({ page, live }) => {
    await live('/namespaces/default/operatives');

    await expect(page.getByTestId('fixed-namespace')).toContainText('default');
    await expect(page.getByTestId('filter-namespace')).toHaveCount(0);

    await page.getByTestId('filter-health').click();
    await page.getByTestId('filter-health-healthy').click();

    await expect(page).toHaveURL(/\/namespaces\/default\/operatives\?health=healthy$/);
  });
});
