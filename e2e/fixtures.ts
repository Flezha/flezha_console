import { test as base, expect, type Page } from '@playwright/test';

/**
 * Opens `path` and waits for its LiveView to finish connecting.
 *
 * Asserting against a page whose LiveView has not connected yet reads the
 * dead-render — the markup Phoenix sends before the socket joins — so events
 * fire into nothing and dynamic content is missing.
 */
async function visitLive(page: Page, path: string): Promise<void> {
  await page.goto(path);

  const main = page.locator('[data-phx-main]');
  await main.waitFor({ state: 'attached', timeout: 15_000 });
  await expect(main).not.toHaveClass(/phx-loading/, { timeout: 15_000 });
}

/**
 * The ids behind every `data-testid` starting with `prefix`.
 *
 * The screens name their rows `operative-row-<id>`, `binding-row-<id>`,
 * `provider-btn-<id>`, so this is how a spec reads back what a table currently
 * holds — and how the count assertions that catch leaked state are built.
 */
export async function testIds(page: Page, prefix: string): Promise<string[]> {
  return page
    .locator(`[data-testid^="${prefix}"]`)
    .evaluateAll(
      (els, p) => els.map((el) => (el.getAttribute('data-testid') ?? '').slice(p.length)),
      prefix,
    );
}

/**
 * `test` with a `live` helper bound to the page, so a spec reads
 * `await live('/audit')` instead of repeating the connect wait everywhere.
 */
export const test = base.extend<{ live: (path: string) => Promise<void> }>({
  live: async ({ page }, use) => {
    await use((path: string) => visitLive(page, path));
  },
});

export { expect } from '@playwright/test';
export type { Page } from '@playwright/test';
