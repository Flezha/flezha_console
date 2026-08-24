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
 * Every health the Convergence Loop can report, in the order
 * `NodeManager.health_kinds/0` lists them.
 *
 * Written once so a health added on the controller side fails in one place
 * rather than silently passing a stale regex in two specs.
 */
export const HEALTH_KINDS = [
  'healthy',
  'suspended',
  'degraded',
  'unbound',
  'failed',
  'unknown',
] as const;

/**
 * What a `data-health` attribute is allowed to say: one named health, or any
 * health the controller can report.
 *
 * Every health assertion goes through this, so none of them can settle for a
 * matcher like `/\w+/` that a typo would satisfy.
 */
export function healthMatcher(expected?: string): string | RegExp {
  return expected ?? new RegExp(`^(${HEALTH_KINDS.join('|')})$`);
}

/** One row's health badge, for an assertion about that row alone. */
export function healthBadge(page: Page, rowTestId: string) {
  return page.getByTestId(rowTestId).getByTestId('health-badge');
}

/**
 * Asserts every health badge under `rowPrefix` carries a health.
 *
 * `expected` is a single health when the caller filtered to one, and omitted
 * when the assertion is only that the column is populated and legitimate.
 */
export async function expectHealthBadges(
  page: Page,
  rowPrefix: string,
  expected?: string,
): Promise<void> {
  const badges = page.locator(`[data-testid^="${rowPrefix}"] [data-testid="health-badge"]`);
  const count = await badges.count();

  expect(count, `expected at least one health badge under ${rowPrefix}`).toBeGreaterThan(0);

  for (let i = 0; i < count; i++) {
    await expect(badges.nth(i)).toHaveAttribute('data-health', healthMatcher(expected));
  }
}

/**
 * Chooses `value` in a `.flz-dropdown` picker, named by its trigger's test id.
 *
 * The pickers are menu buttons rather than native selects — the OS draws a
 * `select`'s menu and it cannot be styled to match — so a spec opens the menu
 * and clicks the row instead of calling `selectOption`.
 */
export async function choose(page: Page, testid: string, value: string): Promise<void> {
  await page.getByTestId(testid).click();
  await page.getByTestId(`${testid}-${value}`).click();
}

/**
 * The hidden input a `.flz-dropdown` picker submits under, so a spec can
 * assert on what it currently holds with `toHaveValue`.
 */
export function chosen(page: Page, testid: string) {
  return page.locator(`#${testid}-value`);
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
