import { test, expect, toggleTheme } from './fixtures';
import type { Page } from '@playwright/test';

/**
 * The shared Flezha theme contract: `data-theme` on `<html>`, storage key
 * `flezha-theme`. With nothing stored the theme is the device's colour scheme
 * and keeps following it; a choice that differs from the device is stored, and
 * toggling back to the device's own scheme forgets it.
 *
 * The pre-paint part cannot be checked by reading the DOM afterwards — by then
 * the right theme is applied either way. So the stored preference is written
 * before the first navigation and the document Phoenix sent is read as text.
 */
const theme = (page: Page) => page.locator('html');
const stored = (page: Page) => page.evaluate(() => localStorage.getItem('flezha-theme'));
const token = (page: Page, name: string) =>
  page.evaluate((n) => getComputedStyle(document.documentElement).getPropertyValue(n).trim(), name);
const rgb = (page: Page, value: string) =>
  page.evaluate((v) => {
    const probe = document.createElement('span');
    probe.style.color = v;
    document.body.append(probe);
    const out = getComputedStyle(probe).color;
    probe.remove();
    return out;
  }, value);

async function freshVisit(page: Page, live: (path: string) => Promise<void>, scheme: 'light' | 'dark') {
  await page.emulateMedia({ colorScheme: scheme });
  await page.goto('/');
  await page.evaluate(() => localStorage.clear());
  await live('/');
}

test.describe('Theme contract', () => {
  test('with nothing stored, the theme follows the device, on a first visit and live', async ({ page, live }) => {
    await freshVisit(page, live, 'light');
    await expect(theme(page)).toHaveAttribute('data-theme', 'light');

    await page.emulateMedia({ colorScheme: 'dark' });
    await expect(theme(page)).toHaveAttribute('data-theme', 'dark');

    await freshVisit(page, live, 'dark');
    await expect(theme(page)).toHaveAttribute('data-theme', 'dark');
    expect(await stored(page)).toBeNull();
  });

  test('a stored preference is applied before the page paints', async ({ page, live }) => {
    await page.emulateMedia({ colorScheme: 'dark' });
    await page.goto('/');
    await page.evaluate(() => localStorage.setItem('flezha-theme', 'light'));

    // The server sets no theme at all; the script inlined in <head> does,
    // before the stylesheet below it is applied.
    const served = await page.evaluate(async () => (await (await fetch('/')).text()).match(/<html[^>]*>/)?.[0]);
    expect(served).not.toContain('data-theme');

    await live('/');
    await expect(theme(page)).toHaveAttribute('data-theme', 'light');
  });

  test('a toggle away from the device is stored, a toggle back forgets it', async ({ page, live }) => {
    await freshVisit(page, live, 'dark');

    await toggleTheme(page);
    await expect(theme(page)).toHaveAttribute('data-theme', 'light');
    await expect.poll(() => stored(page)).toBe('light');

    // Still light after a full reload, not just for this page view.
    await live('/');
    await expect(theme(page)).toHaveAttribute('data-theme', 'light');

    await toggleTheme(page);
    await expect(theme(page)).toHaveAttribute('data-theme', 'dark');
    await expect.poll(() => stored(page)).toBeNull();
  });

  test('the chrome follows the theme and the accent marks where you are', async ({ page, live }) => {
    await freshVisit(page, live, 'dark');
    const bg = (selector: string) =>
      page.locator(selector).evaluate((el) => getComputedStyle(el).backgroundColor);
    const current = page.locator('.flz-sidebar-link[aria-current="page"]');

    const sidebarDark = await bg('.flz-sidebar');
    expect(await current.evaluate((el) => getComputedStyle(el).color)).toBe(
      await rgb(page, await token(page, '--accent-solid')),
    );
    expect(await current.evaluate((el) => getComputedStyle(el).borderLeftColor)).toBe(
      await rgb(page, await token(page, '--accent-solid')),
    );
    expect(await bg('.flz-topbar'), 'the topbar belongs to the page, not the rail').toBe(
      await bg('.flz-canvas'),
    );
    expect(await bg('.flz-topbar')).not.toBe(sidebarDark);
    expect(
      await page.locator('.flz-topbar').evaluate((el) => getComputedStyle(el).borderBottomWidth),
      'a hairline sets the topbar off the content',
    ).toBe('1px');
    for (const [selector, edge] of [
      ['.flz-sidebar', 'borderRightWidth'],
      ['.flz-sidebar-brand', 'borderBottomWidth'],
    ] as const) {
      expect(
        await page.locator(selector).evaluate((el, e) => getComputedStyle(el)[e], edge),
        `${selector} draws no seam across the chrome`,
      ).toBe('0px');
    }

    await toggleTheme(page);
    await expect(theme(page)).toHaveAttribute('data-theme', 'light');

    // Polled, because the colours transition into the new theme.
    expect(await bg('.flz-sidebar'), 'the chrome flips with the canvas').not.toBe(sidebarDark);
    await expect
      .poll(() => bg('.flz-sidebar'))
      .toBe(await rgb(page, await token(page, '--chrome-pale')));
    await expect
      .poll(() => current.evaluate((el) => getComputedStyle(el).color))
      .toBe(await rgb(page, await token(page, '--accent-solid')));
  });

  test('the badger lockup is painted in each theme', async ({ page, live }) => {
    for (const scheme of ['dark', 'light'] as const) {
      await freshVisit(page, live, scheme);
      const logo = page.locator('.flz-sidebar-brand .flz-logo');

      await expect(logo).toBeVisible();
      expect(await logo.evaluate((el) => getComputedStyle(el).maskImage)).toContain(
        'flezha-ui-badger-line-text-white.svg',
      );
      await expect(logo).toHaveAccessibleName('Flezha UI');

      // The proportions the served file declares, so the check follows a
      // regenerated lockup instead of a copied number.
      const svg = await (await page.request.get('/images/flezha-ui-badger-line-text-white.svg')).text();
      const [, width, height] = svg.match(/viewBox="\S+ \S+ (\S+) (\S+)"/)!;
      const box = await logo.boundingBox();
      expect(box?.height).toBeGreaterThan(0);
      expect(box!.width / box!.height, 'the lockup keeps its own proportions').toBeCloseTo(
        Number(width) / Number(height),
        1,
      );

      const brandRow = await page.locator('.flz-sidebar-brand').boundingBox();
      const topbar = await page.locator('.flz-topbar').boundingBox();
      expect(brandRow!.height, 'the brand row and the topbar share one bottom edge').toBe(
        topbar!.height,
      );
      expect(await logo.evaluate((el) => getComputedStyle(el).backgroundColor)).toBe(
        await rgb(page, await token(page, '--logo-ink')),
      );
    }
  });

  test('the choice survives live navigation and the toggle still works', async ({ page, live }) => {
    await freshVisit(page, live, 'dark');
    await toggleTheme(page);
    await expect(theme(page)).toHaveAttribute('data-theme', 'light');

    await page.locator('.flz-sidebar-link[href="/namespaces"]').click();
    await expect(page).toHaveURL(/\/namespaces$/);
    await expect(theme(page)).toHaveAttribute('data-theme', 'light');

    // The current destination is marked on the rail, server-side.
    await expect(page.locator('.flz-sidebar-link[href="/namespaces"]')).toHaveAttribute(
      'aria-current',
      'page',
    );

    await toggleTheme(page);
    await expect(theme(page)).toHaveAttribute('data-theme', 'dark');
  });

  test('the console sets type in flezha.com\'s faces and serves the badger icons', async ({
    page,
    live,
  }) => {
    const own = new URL(test.info().project.use.baseURL!).host;
    const thirdParty: string[] = [];
    page.on('request', (r) => {
      if (new URL(r.url()).host !== own) thirdParty.push(r.url());
    });

    await live('/');

    const faces = await page.evaluate(() =>
      [...document.fonts].map((f) => `${f.family}:${f.status}`),
    );
    expect(faces).toContain('Inter:loaded');
    expect(faces).toContain('Space Grotesk:loaded');
    expect(faces).toContain('JetBrains Mono:loaded');
    expect(thirdParty, 'no font or icon may come from a third party').toEqual([]);

    // The badger without a background: a dark mark for a light browser, a
    // white one for a dark browser, and the SVG that follows either.
    const icons = await page
      .locator('link[rel="icon"]')
      .evaluateAll((links) => links.map((l) => `${l.getAttribute('media') ?? ''} ${l.getAttribute('href')}`));
    expect(icons).toEqual([
      '(prefers-color-scheme: light) /images/favicon-mark-dark-32.png',
      '(prefers-color-scheme: dark) /images/favicon-mark-white-32.png',
      ' /favicon.svg',
    ]);

    for (const [path, type] of [
      ['/favicon.svg', 'image/svg+xml'],
      ['/images/favicon-mark-dark-32.png', 'image/png'],
      ['/images/favicon-mark-white-32.png', 'image/png'],
    ]) {
      const res = await page.request.get(path);
      expect(res.status(), path).toBe(200);
      expect(res.headers()['content-type'], path).toContain(type);
    }
  });
});

/**
 * The brand on the screens outside the shell: the login screen, in each
 * theme. The page-health guards fail any logo or favicon that does not load.
 */
test.describe('Brand outside the shell', () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test('the login screen is one centred form, its lockup in the logo\'s own two colours, its toggle working', async ({
    page,
  }) => {
    const ink = { dark: 'rgb(255, 255, 255)', light: 'rgb(40, 11, 42)' };

    for (const scheme of ['dark', 'light'] as const) {
      await page.emulateMedia({ colorScheme: scheme });
      await page.goto('/users/log-in');
      await expect(theme(page)).toHaveAttribute('data-theme', scheme);

      const logo = page.locator('.fui-brand .fui-logo').first();
      await expect(logo).toBeVisible();
      expect(await logo.evaluate((el) => getComputedStyle(el).maskImage)).toContain(
        'flezha-ui-badger-line-text-white.svg',
      );

      expect(await logo.evaluate((el) => getComputedStyle(el).backgroundColor)).toBe(ink[scheme]);

      await expect(page.locator('img[src*="badger-laptop"]')).toHaveCount(0);
      await expect(page.getByTestId('theme-toggle')).toBeVisible();

      // Centred: the form's middle sits on the page's middle.
      const box = (await page.locator('#login_form_password').boundingBox())!;
      const width = page.viewportSize()!.width;
      expect(Math.abs(box.x + box.width / 2 - width / 2)).toBeLessThan(4);
    }

    // Left on the light login screen by the loop above.
    await page.getByTestId('theme-toggle').click();
    await expect(theme(page)).toHaveAttribute('data-theme', 'dark');
  });

  test('an unknown address shows the not-found page with its mascot, not the debugger', async ({ page, pageHealth }) => {
    pageHealth.allow(/no-such-relay/, 'the address is unknown on purpose');
    const response = await page.goto('/default/relays/no-such-relay');
    expect(response!.status()).toBe(404);

    await expect(page.getByTestId('not-found')).toBeVisible();
    const mascot = page.locator('img[src*="badger-not-found.png"]');
    await expect
      .poll(() => mascot.evaluate((img: HTMLImageElement) => img.complete && img.naturalWidth > 0))
      .toBe(true);
  });
});
