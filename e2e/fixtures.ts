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
 * The factory ids the start form offers, without its placeholder option.
 *
 * Read by value rather than by label: the labels carry the factory's
 * description and a mark for the ones no runner serves, which is what an
 * operator reads and not what a spec should match on.
 */
export async function factoryOptions(page: Page): Promise<string[]> {
  const select = page.getByTestId('input-factory-id');
  await expect(select).toBeEnabled();

  return select
    .locator('option')
    .evaluateAll((opts) =>
      opts.map((o) => (o as HTMLOptionElement).value).filter((v) => v !== ''),
    );
}

/**
 * The factory the dev stack documents for each kind.
 *
 * The runner registers its whole catalogue, most of which are workflow
 * factories — and the first one alphabetically (`bench_chain_1`) is one of
 * them. Taking whichever sorts first asks the controller to run a workflow as
 * a stream, which it refuses.
 *
 * The workflow factory is the long-lived one: `echo_workflow` runs once and
 * completes, so an instance started from it is already in the finished listing
 * by the time a spec looks for its row.
 */
const SEEDED_FACTORY: Record<string, string> = {
  stream: 'store_input',
  workflow: 'chat_loop_workflow',
};

/**
 * Starts an operative through the launcher, from whichever screen is open.
 *
 * One helper because there is one form: the namespace screen pins its
 * namespace and the operatives index asks for one, and a spec that drove them
 * separately would stop catching the drift the shared launcher exists to
 * prevent.
 *
 * Returns the factory it chose, so a caller can assert on it.
 */
export async function startOperative(
  page: Page,
  id: string,
  opts: { namespace?: string; kind?: string; factory?: string } = {},
): Promise<string> {
  const kind = opts.kind ?? 'stream';

  await page.getByTestId('start-operative-btn').click();
  await expect(page.getByTestId('start-modal')).toBeVisible();

  // Before the factory: changing the namespace re-reads its catalog, which
  // re-renders the factory selector and drops whatever was chosen.
  if (opts.namespace) {
    await page.getByTestId('input-namespace').selectOption(opts.namespace);
  }

  await page.getByTestId('input-operative-id').fill(id);
  await page.getByTestId('input-kind').selectOption(kind);

  const factory = opts.factory ?? (await preferredFactory(page, kind));
  await page.getByTestId('input-factory-id').selectOption(factory);

  await page.getByTestId('start-submit-btn').click();
  await expect(page.getByTestId('start-modal')).toHaveCount(0);

  return factory;
}

async function preferredFactory(page: Page, kind: string): Promise<string> {
  const options = await factoryOptions(page);

  expect(options.length, 'at least one factory must be available').toBeGreaterThan(0);

  const seeded = SEEDED_FACTORY[kind];
  return seeded && options.includes(seeded) ? seeded : options[0];
}

/**
 * Stops `id` from the namespace screen the caller is already on.
 *
 * Tolerating an already-stopped operative is what makes this safe to call from
 * `finally` after the test stopped it itself; it never skips an assertion.
 */
export async function stopOperative(page: Page, id: string): Promise<void> {
  const row = page.getByTestId(`operative-row-${id}`);
  if ((await row.count()) === 0) return;

  await page.getByTestId(`stop-operative-${id}`).click();
  await expect(page.getByTestId('stop-confirm-modal')).toBeVisible();
  await page.getByTestId('stop-confirm-btn').click();
  await expect(row).toHaveCount(0);
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
