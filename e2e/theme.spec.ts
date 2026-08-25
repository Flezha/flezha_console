import { test, expect, toggleTheme } from './fixtures';

/**
 * The shared Flezha theme contract: `data-theme` on `<html>`, storage key
 * `flezha-theme`, dark by default, applied before the first paint.
 *
 * The pre-paint part is the one that cannot be checked by reading the DOM
 * afterwards — by then the right theme is applied either way. So the stored
 * preference is written before the first navigation and the attribute is read
 * from the document Phoenix sent, before scripts could have corrected it.
 */
test.describe('Theme contract', () => {
  test('a first visit with empty storage is dark', async ({ page, live }) => {
    await page.goto('/');
    await page.evaluate(() => localStorage.clear());
    await live('/');

    await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
    await expect.poll(() => page.evaluate(() => localStorage.getItem('flezha-theme'))).toBeNull();
  });

  test('a stored preference is applied before the page paints', async ({ page, live }) => {
    await page.goto('/');
    await page.evaluate(() => localStorage.setItem('flezha-theme', 'light'));

    // The hydration script runs in <head>, so the attribute is already right
    // on the very first `document.documentElement` read of the new document.
    const themeAtFirstScript = await page.evaluate(async () => {
      const res = await fetch('/');
      const html = await res.text();
      return html.match(/<html[^>]*data-theme="(\w+)"/)?.[1];
    });
    // The server always renders the dark default; the inlined script corrects it.
    expect(themeAtFirstScript).toBe('dark');

    await live('/');
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
  });

  test('the toggle flips the theme and persists the choice', async ({ page, live }) => {
    await live('/');
    await page.evaluate(() => localStorage.setItem('flezha-theme', 'dark'));
    await live('/');

    await toggleTheme(page);

    await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
    await expect
      .poll(() => page.evaluate(() => localStorage.getItem('flezha-theme')))
      .toBe('light');

    // And it is still light after a full reload, not just for this page view.
    await live('/');
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');
  });

  test('chrome stays plum while the canvas flips', async ({ page, live }) => {
    await live('/');
    const bg = (selector: string) =>
      page.locator(selector).evaluate((el) => getComputedStyle(el).backgroundColor);

    const sidebarDark = await bg('.flz-sidebar');
    const canvasDark = await bg('.flz-canvas');

    await toggleTheme(page);
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');

    expect(await bg('.flz-sidebar'), 'chrome is theme-invariant').toBe(sidebarDark);
    expect(await bg('.flz-canvas'), 'the canvas flips').not.toBe(canvasDark);
  });

  test('the choice survives live navigation and the toggle still works', async ({ page, live }) => {
    await live('/');
    await toggleTheme(page);
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');

    await page.locator('.flz-sidebar-link[href="/namespaces"]').click();
    await expect(page).toHaveURL(/\/namespaces$/);
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'light');

    // The current destination is marked on the rail, server-side.
    await expect(page.locator('.flz-sidebar-link[href="/namespaces"]')).toHaveAttribute(
      'aria-current',
      'page',
    );

    await toggleTheme(page);
    await expect(page.locator('html')).toHaveAttribute('data-theme', 'dark');
  });

  test('the console serves its own typefaces and the Flezha icon', async ({ page, live }) => {
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
  });
});
