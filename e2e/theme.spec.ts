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
  test('a first visit follows the device, light or dark', async ({ page, live }) => {
    await freshVisit(page, live, 'light');
    await expect(theme(page)).toHaveAttribute('data-theme', 'light');

    await freshVisit(page, live, 'dark');
    await expect(theme(page)).toHaveAttribute('data-theme', 'dark');
    expect(await stored(page)).toBeNull();
  });

  test('with nothing stored, a device switch is followed live', async ({ page, live }) => {
    await freshVisit(page, live, 'light');
    await expect(theme(page)).toHaveAttribute('data-theme', 'light');

    await page.emulateMedia({ colorScheme: 'dark' });
    await expect(theme(page)).toHaveAttribute('data-theme', 'dark');
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
    expect(
      await page.locator('.flz-topbar').evaluate((el) => getComputedStyle(el).backgroundImage),
      'the topbar wears the chrome band',
    ).toContain('linear-gradient');

    await toggleTheme(page);
    await expect(theme(page)).toHaveAttribute('data-theme', 'light');

    expect(await bg('.flz-sidebar'), 'the chrome flips with the canvas').not.toBe(sidebarDark);
    expect(await bg('.flz-sidebar')).toBe(await rgb(page, await token(page, '--chrome-pale')));
    expect(await current.evaluate((el) => getComputedStyle(el).color)).toBe(
      await rgb(page, await token(page, '--accent-solid')),
    );
  });

  test('the badger lockup is painted in each theme', async ({ page, live }) => {
    for (const scheme of ['dark', 'light'] as const) {
      await freshVisit(page, live, scheme);
      const logo = page.locator('.flz-sidebar-brand .flz-logo');

      await expect(logo).toBeVisible();
      expect(await logo.evaluate((el) => getComputedStyle(el).maskImage)).toContain(
        'flezha-badger-white.svg',
      );
      expect((await logo.boundingBox())?.height).toBeGreaterThan(0);
      await expect(page.locator('.flz-sidebar-brand .flz-brand-name')).toHaveText('Flezha UI');
      expect(await logo.evaluate((el) => getComputedStyle(el).backgroundColor)).toBe(
        await rgb(page, await token(page, '--text-primary')),
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

  test('the console serves its own typefaces and the badger icons', async ({ page, live }) => {
    const thirdParty: string[] = [];
    page.on('request', (r) => {
      const url = new URL(r.url());
      if (url.host !== 'localhost:4000') thirdParty.push(r.url());
    });

    await live('/');

    const faces = await page.evaluate(() =>
      [...document.fonts].map((f) => `${f.family}:${f.status}`),
    );
    expect(faces).toContain('Inter:loaded');
    expect(faces).toContain('Space Grotesk:loaded');
    expect(faces).toContain('JetBrains Mono:loaded');
    expect(thirdParty, 'no font or icon may come from a third party').toEqual([]);

    await expect(page.locator('link[rel="icon"]')).toHaveAttribute('href', '/favicon.svg');

    for (const [path, type] of [
      ['/favicon.svg', 'image/svg+xml'],
      ['/favicon.ico', 'image/'],
    ]) {
      const res = await page.request.get(path);
      expect(res.status(), path).toBe(200);
      expect(res.headers()['content-type'], path).toContain(type);
    }
  });
});

/**
 * The brand on the screens outside the shell: the login screen, in each
 * theme, and the 404 page's mascot. The page-health guards fail any
 * logo, mascot or favicon that does not load.
 */
test.describe('Brand outside the shell', () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test('the login screen paints the badger lockup and its mascot in each theme', async ({ page }) => {
    for (const scheme of ['dark', 'light'] as const) {
      await page.emulateMedia({ colorScheme: scheme });
      await page.goto('/users/log-in');
      await expect(theme(page)).toHaveAttribute('data-theme', scheme);

      const logo = page.locator('.flz-brand .flz-logo').first();
      await expect(logo).toBeVisible();
      expect(await logo.evaluate((el) => getComputedStyle(el).maskImage)).toContain('flezha-badger');

      const mascot = page.locator('img[src*="badger-laptop"]');
      await expect(mascot).toBeVisible();
      expect(await mascot.evaluate((img) => (img as HTMLImageElement).naturalWidth)).toBeGreaterThan(0);
    }
  });

  test('the 404 page’s mascot is served', async ({ page }) => {
    // The dev server answers an unknown route with Phoenix's debug page, so
    // the 404 page itself is asserted in `error_html_test.exs`.
    const res = await page.request.get('/images/badger-not-found.webp');
    expect(res.status()).toBe(200);
    expect(res.headers()['content-type']).toContain('image/webp');
  });
});
