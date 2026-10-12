import {
  test,
  expect,
  closeSection,
  openPalette,
  openSection,
  timelineSamples,
  withStepsRelay,
  ADVANCE_WINDOW_MS,
  expectAdvances,
  openPage,
} from './fixtures';

/**
 * The shell, in a browser: the four-section rail, the scope in the route, the
 * crumb trail, the tabs on a relay, the palette's keyboard, and a section
 * remembering it was folded.
 *
 * The LiveView suite proves the server renders these. What only a browser can
 * prove is that the keyboard reaches the palette, that a tab navigates to its
 * own route, and that a fold survives a reload — all of which live in the
 * client.
 */

const RELAY = '/namespaces/default/relays/testnet_store_1';

test.describe('The console shell', () => {
  test('the rail groups the namespace, what needs attention, the platform and monitoring', async ({
    page,
    live,
  }) => {
    await live('/namespaces/default');

    const rail = page.locator('.flz-sidebar-nav');
    await expect(rail.locator('.flz-sidebar-section')).toHaveText([
      /Namespace\s*default/,
      'Attention',
      'Platform',
      'Monitoring',
    ]);
    // Every relay across namespaces is the Relays screen's own switch.
    await expect(rail.locator('a[href="/relays"]')).toHaveCount(0);
    await expect(rail.locator('a[href="/namespaces/default/relays"]')).toBeVisible();
    await expect(rail.locator('a[href="/namespaces/default/plugins"]')).toBeVisible();
    await expect(rail.locator('a[href="/namespaces/default/schedules"]')).toBeVisible();
  });

  test('a platform screen keeps the namespace last worked in', async ({ page, live }) => {
    await live('/namespaces/default/relays');

    // The address names no namespace from here on, so only the remembered
    // scope can keep the rail and the picker on it.
    await page.locator('.flz-sidebar-nav a[href="/cluster"]').click();
    await expect(page).toHaveURL(/\/cluster$/);

    await expect(page.getByTestId('namespace-picker')).toContainText('default');
    await expect(page.getByTestId('no-namespace-scoped')).toHaveCount(0);
    await expect(
      page.locator('.flz-sidebar-nav a[href="/namespaces/default/relays"]'),
    ).toBeVisible();
  });

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

  test('a scoped route marks its own entry and not the platform twin', async ({ page, live }) => {
    await live('/namespaces/default/relays');

    const rail = page.locator('.flz-sidebar-nav');
    await expect(rail.locator('[aria-current="page"]')).toHaveCount(1);
    await expect(rail.locator('a[href="/namespaces/default/relays"]')).toHaveAttribute(
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
    await live(`${RELAY}/state`);

    const trail = page.getByTestId('breadcrumb');
    await expect(trail).toBeVisible();
    await expect(trail).toContainText('default');
    await expect(trail).toContainText('testnet_store_1');

    // The current view is the last crumb, marked and not a link.
    await expect(trail.locator('[aria-current="page"]')).toHaveText('State');

    // Every ancestor is a link to its own screen.
    const crumbs = await trail.locator('a').evaluateAll((links) => links.map((a) => a.getAttribute('href')!));
    expect(crumbs).toEqual(
      expect.arrayContaining(['/namespaces/default', '/namespaces/default/relays', RELAY]),
    );
    for (const href of crumbs) {
      await live(`${RELAY}/state`);
      await page.getByTestId('breadcrumb').locator(`a[href="${href}"]`).click();
      await expect(page).toHaveURL((url) => url.pathname === href);
    }

    // A rail destination has no trail to render.
    await live('/cluster');
    await expect(page.getByTestId('breadcrumb')).toHaveCount(0);
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
});

test.describe("A relay's views", () => {
  test('are a tab strip that navigates between three routes', async ({ page, live }) => {
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
  test('opens on the shortcut and reaches a relay by id', async ({ page, live }) => {
    await live('/audit');

    await openPalette(page);
    await page.getByTestId('command-palette-input').fill('testnet_store_1');

    await expect(page.getByTestId('command-palette-results')).toContainText('testnet_store_1');
    const match = page.getByTestId('command-palette-relay-testnet_store_1');
    await expect(match).toBeVisible();
    await expect(match).toContainText('default');

    await match.click();
    await expect(page).toHaveURL(new RegExp(`${RELAY}$`));
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

  test('closes on Escape and on a click outside it, leaving the screen where it was', async ({
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
  });

  test('does not steal the shortcut from a field being typed into', async ({ page, live }) => {
    await live('/dlq');

    await page.getByTestId('dlq-filter').click();
    await page.keyboard.press('Control+k');

    await expect(page.getByTestId('command-palette')).toHaveCount(0);
  });
});

test.describe('A screen that refreshes', () => {
  test('moves its controller-fed figures on its own, and holds them still while paused', async ({
    page,
    live,
  }) => {
    const relay = '/namespaces/default/relays/testnet_store_1';

    await live(relay);
    await expect(page.getByTestId('topology-timeline')).toBeVisible({ timeout: ADVANCE_WINDOW_MS });
    await expectAdvances(() => timelineSamples(page), 'the refreshing timeline');

    await page.getByTestId('liveness-toggle').click();
    await expect(page.getByTestId('liveness-state')).toContainText('Paused');
    const held = await timelineSamples(page);

    // A second copy of the screen keeps refreshing; once it has ticked twice,
    // the paused one has missed at least one tick it would have taken.
    const other = await openPage(page, relay);
    await expect(other.getByTestId('topology-timeline')).toBeVisible({ timeout: ADVANCE_WINDOW_MS });
    await expectAdvances(() => timelineSamples(other), 'the other copy, once');
    await expectAdvances(() => timelineSamples(other), 'the other copy, twice');
    await other.close();

    expect(await timelineSamples(page)).toBe(held);
    await page.getByTestId('liveness-toggle').click();
    await expectAdvances(() => timelineSamples(page), 'the resumed timeline');
  });

  test('states its liveness and can be held still', async ({ page, live }) => {
    await live('/relays');

    const state = page.getByTestId('liveness-state');
    await expect(state).toContainText('Every 5s');

    await page.getByTestId('liveness-toggle').click();
    await expect(state).toContainText('Paused');

    await page.getByTestId('liveness-toggle').click();
    await expect(state).toContainText('Every 5s');
  });
});

test.describe('Relay list filters', () => {
  test('are written to the query string and reversed by the back button', async ({
    page,
    live,
  }) => {
    await withStepsRelay(page, async (id) => {
      await live('/relays');

      await page.getByTestId('filter-run').click();
      await page.getByTestId('filter-run-steps').click();

      await expect(page).toHaveURL(/\?.*run=steps/);
      await expect(page.getByTestId(`relay-index-row-${id}`)).toBeVisible();
      await expect(page.getByTestId('relay-index-row-testnet_store_1')).toHaveCount(0);

      await page.goBack();

      await expect(page).not.toHaveURL(/run=steps/);
      await expect(page.getByTestId('relay-index-row-testnet_store_1')).toBeVisible();
    });
  });

  test('a scoped listing keeps its namespace out of the query string', async ({ page, live }) => {
    await live('/namespaces/default/relays');

    await expect(page.getByTestId('scope-namespace')).toHaveAttribute('aria-current', 'true');
    await expect(page.getByTestId('scope-namespace')).toContainText('default');
    await expect(page.getByTestId('filter-namespace')).toHaveCount(0);

    await page.getByTestId('filter-health').click();
    await page.getByTestId('filter-health-healthy').click();

    await expect(page).toHaveURL(/\/namespaces\/default\/relays\?health=healthy$/);
  });
});
