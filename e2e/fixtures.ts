import { test as base, expect, type Page } from '@playwright/test';
import { submitLogin } from './global-setup';

/** Unique per test, so a leftover from a failed run cannot collide. */
export function uniqueId(prefix: string): string {
  const ts = Date.now().toString(36).slice(-4);
  const rand = Math.random().toString(36).slice(2, 5);
  return `${prefix}_${ts}_${rand}`;
}

/**
 * Opens `path` and waits for its LiveView to finish connecting.
 *
 * Asserting against a page whose LiveView has not connected yet reads the
 * dead-render — the markup Phoenix sends before the socket joins — so events
 * fire into nothing and dynamic content is missing.
 */
export async function visitLive(page: Page, path: string): Promise<void> {
  await page.goto(path);

  const main = page.locator('[data-phx-main]');
  await main.waitFor({ state: 'attached', timeout: 15_000 });
  await expect(main).not.toHaveClass(/phx-loading/, { timeout: 15_000 });
}

/**
 * The ids behind every `data-testid` starting with `prefix`.
 *
 * The screens name their rows `relay-row-<id>`, `binding-row-<id>`,
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
 * Every health verdict the controller can report, in the order
 * `NodeManager.health_verdicts/0` lists them — core's own rank order.
 *
 * Written once so a health added on the controller side fails in one place
 * rather than silently passing a stale regex in two specs.
 */
export const HEALTH_VERDICTS = [
  'healthy',
  'unknown',
  'suspended',
  'degraded',
  'recovering',
  'unbound',
  'failed',
  'parked',
] as const;

/**
 * What a `data-health` attribute is allowed to say: one named health, or any
 * health the controller can report.
 *
 * Every health assertion goes through this, so none of them can settle for a
 * matcher like `/\w+/` that a typo would satisfy.
 */
export function healthMatcher(expected?: string): string | RegExp {
  return expected ?? new RegExp(`^(${HEALTH_VERDICTS.join('|')})$`);
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
 * The factory the dev stack documents for each run.
 *
 * The runner registers its whole catalogue, most of which are steps factories
 * — and the first one alphabetically is one of them. Taking whichever sorts
 * first would start a steps relay where a spec expects a flow one.
 *
 * The steps factory is the long-lived one: `echo_steps` runs once and
 * completes, so a relay started from it is already in the finished listing by
 * the time a spec looks for its row.
 */
export const SEEDED_FACTORY = {
  flow: 'store_input',
  steps: 'chat_loop_steps',
} as const;

export type Run = keyof typeof SEEDED_FACTORY;

/**
 * Starts a relay through the launcher, from whichever screen is open.
 *
 * One helper because there is one form: the namespace screen pins its
 * namespace and the relays index asks for one, and a spec that drove them
 * separately would stop catching the drift the shared launcher exists to
 * prevent. How the relay runs is its factory's, so `run` only picks the
 * seeded factory of that run; the form asks for no run.
 *
 * The form answers with the id the relay runs under and a link to it, and
 * stays open until it is dismissed; this reads that answer and closes it.
 *
 * Returns the factory it chose, so a caller can assert on it.
 */
export async function startRelay(
  page: Page,
  id: string,
  opts: { namespace?: string; run?: Run; factory?: string } = {},
): Promise<string> {
  const run = opts.run ?? 'flow';

  await page.getByTestId('start-relay-btn').click();
  await expect(page.getByTestId('start-modal')).toBeVisible();

  // Before the factory: changing the namespace re-reads its catalog, which
  // re-renders the factory selector and drops whatever was chosen.
  if (opts.namespace) {
    await page.getByTestId('input-namespace').selectOption(opts.namespace);
  }

  const factory = opts.factory ?? (await preferredFactory(page, run));
  await page.getByTestId('input-factory-id').selectOption(factory);
  await page.getByTestId('input-relay-id').fill(id);

  await page.getByTestId('start-submit-btn').click();
  await expect(page.getByTestId('start-result')).toBeVisible();
  await expect(page.getByTestId('start-result-link')).toHaveText(id);

  await page.getByTestId('start-done-btn').click();
  await expect(page.getByTestId('start-modal')).toHaveCount(0);

  return factory;
}

async function preferredFactory(page: Page, run: Run): Promise<string> {
  const options = await factoryOptions(page);

  expect(options.length, 'at least one factory must be available').toBeGreaterThan(0);

  const seeded = SEEDED_FACTORY[run];
  return options.includes(seeded) ? seeded : options[0];
}

/**
 * Stops `id` from the namespace screen the caller is already on.
 *
 * Tolerating an already-stopped relay is what makes this safe to call from
 * `finally` after the test stopped it itself; it never skips an assertion. A
 * steps relay stops cooperatively and leaves the listing once its in-flight
 * work is done, so the wait allows for that.
 */
export async function stopRelay(page: Page, id: string): Promise<void> {
  const row = page.getByTestId(`relay-row-${id}`);
  if ((await row.count()) === 0) return;

  await page.getByTestId(`stop-relay-${id}`).click();
  await expect(page.getByTestId('stop-confirm-modal')).toBeVisible();
  await page.getByTestId('stop-confirm-btn').click();
  await expect(row).toHaveCount(0, { timeout: 20_000 });
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
 * Puts one of a long screen's sections into the state a spec needs, and waits
 * for its body to follow.
 *
 * Idempotent, so a spec says what it needs on screen without having to know
 * how it got there — a section a breached quota forced open is left alone.
 */
async function foldSection(page: Page, key: string, open: boolean): Promise<void> {
  const toggle = page.getByTestId(`section-toggle-${key}`);
  await expect(toggle).toBeVisible();

  if ((await toggle.getAttribute('aria-expanded')) !== String(open)) {
    await toggle.click();
  }

  const body = page.getByTestId(`section-body-${key}`);
  await (open ? expect(body).toBeVisible() : expect(body).toHaveCount(0));
}

/** Unfolds a section, for a spec reading what is inside it. */
export const openSection = (page: Page, key: string) => foldSection(page, key, true);

/** Folds a section shut, for a spec asserting the choice is remembered. */
export const closeSection = (page: Page, key: string) => foldSection(page, key, false);

/**
 * Flips the theme through the account menu, where the toggle now lives.
 *
 * The menu closes on the click, so the page is left as the spec found it.
 */
export async function toggleTheme(page: Page): Promise<void> {
  await page.getByTestId('account-menu').click();
  await page.locator('[data-flz-theme-toggle]').click();
}

/** Opens the command palette with the shortcut it is bound to. */
export async function openPalette(page: Page): Promise<void> {
  await page.keyboard.press('Control+k');
  await expect(page.getByTestId('command-palette')).toBeVisible();
}

/**
 * Runs `body` against a durable steps relay started for it, and stops that
 * relay afterwards whatever happens.
 *
 * A steps relay that no input reaches does not stay up for the length of a
 * suite run, so a test that needs one starts its own rather than leaning on a
 * seed. The relay runs the seeded `steps` factory under a run-unique id.
 */
export async function withStepsRelay(
  page: Page,
  body: (id: string) => Promise<void>,
): Promise<void> {
  const id = uniqueId('pw_steps');

  await visitLive(page, '/namespaces/default');
  await startRelay(page, id, { run: 'steps' });

  try {
    await body(id);
  } finally {
    await visitLive(page, '/namespaces/default');
    await stopRelay(page, id);
  }
}

/**
 * Unique per run, so a leftover from a failed run cannot collide.
 *
 * Kept short deliberately: the controller allows 11 bytes, because the cron
 * instance id it composes (`<name>@<slot-iso>`) must fit the 32-byte relay
 * id limit.
 */
export function uniqueScheduleName(prefix = 'pw'): string {
  return `${prefix}${Date.now().toString(36).slice(-6)}`;
}

export async function openScheduleForm(page: Page): Promise<void> {
  await page.getByTestId('schedule-new-btn').click();
  await expect(page.getByTestId('schedule-form-modal')).toBeVisible();
}

/**
 * Fills the form, choosing the factory rather than typing it.
 *
 * The target's namespace and factory are now offered from what the controller
 * reports, so a spec that typed an id would be exercising a path only an
 * unreachable controller reaches.
 */
export async function fillScheduleForm(
  page: Page,
  name: string,
  cron: string,
  factory: string,
): Promise<void> {
  await page.getByTestId('schedule-input-name').fill(name);
  await page.getByTestId('schedule-input-cron').fill(cron);
  await page.getByTestId('schedule-input-namespace').selectOption('default');
  await page.getByTestId('schedule-input-factory').selectOption(factory);
}

/**
 * Cleanup, so a failure does not leave a cron job armed.
 *
 * Tolerating an already-removed schedule is what makes this safe to call from
 * `finally` after the test removed it itself; it never skips an assertion.
 */
export async function removeSchedule(page: Page, name: string): Promise<void> {
  const row = page.getByTestId(`schedule-row-${name}`);
  if ((await row.count()) === 0) return;

  await page.getByTestId(`schedule-remove-${name}`).click();
  await page.getByTestId('schedule-remove-confirm').click();
  await expect(row).toHaveCount(0);
}

/**
 * Disables `name` from the plugins screen, whatever any relay screen shows.
 * Safe to call from `finally`: a plugin already gone is left alone.
 */
export async function disablePlugin(page: Page, name: string): Promise<void> {
  await visitLive(page, '/namespaces/default/plugins');
  const row = page.getByTestId(`plugin-row-${name}`);
  if ((await row.count()) === 0) return;

  await page.getByTestId(`plugin-disable-${name}`).click();
  await page.getByTestId('plugin-disable-confirm').click();
  await expect(row).toHaveCount(0);
}

/**
 * Opens the settings screen. Settings sits behind sudo mode, whose window is
 * shorter than a full suite run, so this re-authenticates rather than trusting
 * the shared session. The email field is readonly on the re-auth form — only
 * the password is asked for.
 */
export async function openSettings(page: Page): Promise<void> {
  await page.goto('/users/settings');

  if (page.url().includes('/users/log-in')) {
    await submitLogin(page);
    await page.waitForURL(/\/users\/settings$/);
  }

  await expect(page.getByTestId('flezha-token-settings')).toBeVisible();
}

/**
 * Clears the token stored for the signed-in user, leaving the service token in
 * charge. Safe from `finally`: with none stored it does nothing.
 */
export async function clearStoredToken(page: Page): Promise<void> {
  await openSettings(page);

  if (await page.locator('#clear_flezha_token').count()) {
    await page.locator('#clear_flezha_token button').click();
    await expect(page.getByTestId('flezha-token-binding')).toContainText('using the service token');
  }
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
