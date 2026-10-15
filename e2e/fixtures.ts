import { execFileSync } from 'node:child_process';
import { test as base, expect, type Browser, type Locator, type Page, type TestInfo } from '@playwright/test';
import { devElixir, submitLogin, uniqueId, workerState, workerUser } from './global-setup';

export { uniqueId };

/**
 * Runs the published operation `door` on the dev controller as `flz` sends it
 * (`priv/dev/cli_call.exs` inside `fui_web`), so the controller sees a CLI
 * call, and answers its parsed JSON.
 */
export function cliCall(door: string, args: unknown[]): unknown {
  return JSON.parse(
    devElixir(`cliCall ${door}`, ['/flezha_ui/priv/dev/cli_call.exs', door, JSON.stringify(args)]),
  );
}

/**
 * Sends each of `payloads` to `relay`'s `channel` as `flz relay send` does, in
 * order and from one node, so a test that needs many records pays for one
 * boot. Throws when any send is refused.
 */
export function sendRecords(relay: string, payloads: string[], channel = 'input', namespace = 'default'): void {
  devElixir(`sending ${payloads.length} records to ${relay}`, [
    '/flezha_ui/priv/dev/cli_call.exs',
    'Relay.send',
    ...payloads.map((payload) => JSON.stringify([namespace, relay, payload, channel])),
  ]);
}

/**
 * Creates a confirmed console user through `mix flezha_ui.create_user`, the
 * only way an account is made, so a test that needs one runs the operator's
 * own command.
 */
export function createConsoleUser(email: string, password: string): void {
  try {
    execFileSync(
      'docker',
      ['exec', 'fui_web', 'mix', 'flezha_ui.create_user', email, '--password', password],
      { encoding: 'utf8', stdio: 'pipe' },
    );
  } catch (error) {
    const { stdout = '', stderr = '' } = error as { stdout?: string; stderr?: string };
    throw new Error(`creating ${email} failed:\n${stdout}${stderr}`);
  }
}

/**
 * Deletes a console user a test made, with its sessions. The console
 * offers no screen that deletes an account, so a test that made one removes
 * it here. Safe from `finally`: an email with no user is left alone.
 */
export function deleteConsoleUser(email: string): void {
  devElixir(`deleting ${email}`, ['/flezha_ui/priv/dev/console_users.exs', 'delete', email]);
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
  await main.waitFor({ state: 'attached' });
  await expect(main).not.toHaveClass(/phx-loading/);
}

/** The pipeline graph fits its panel at `width`: neither it nor the page scrolls sideways. */
export async function expectGraphFits(page: Page, width: number): Promise<void> {
  const { sideways, canvas } = await page.evaluate(() => {
    const el = document.querySelector('[data-testid="topology-canvas"]')!;
    return {
      sideways: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      canvas: el.scrollWidth - el.clientWidth,
    };
  });
  expect(sideways, `the page must not scroll sideways at ${width}px`).toBeLessThanOrEqual(0);
  expect(canvas, `the graph fits rather than scrolls at ${width}px`).toBeLessThanOrEqual(0);
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
 * The factory ids the start flow's first step offers to choose: the served
 * ones, read by id rather than by the description an operator reads.
 */
export async function factoryOptions(page: Page): Promise<string[]> {
  await expect(page.getByTestId('factory-choices')).toBeVisible();

  return page
    .locator('[data-testid^="factory-choice-"]:not([disabled])')
    .evaluateAll((els) =>
      els.map((el) => (el.getAttribute('data-testid') ?? '').slice('factory-choice-'.length)),
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
 * The flow walks factory, details and review; it answers with the id the
 * relay runs under and a link to it, and stays open until it is dismissed.
 * This reads that answer and closes it.
 *
 * Returns the factory it chose, so a caller can assert on it.
 */
export async function startRelay(
  page: Page,
  id: string,
  opts: { namespace?: string; run?: Run; factory?: string } = {},
): Promise<string> {
  const run = opts.run ?? 'flow';

  await openStart(page);

  // Before the factory: changing the namespace re-reads its catalog, which
  // re-renders the factory choices and drops whatever was chosen.
  if (opts.namespace) {
    await page.getByTestId('input-namespace').selectOption(opts.namespace);
  }

  const factory = opts.factory ?? (await preferredFactory(page, run));
  await chooseFactory(page, factory);
  await page.getByTestId('input-relay-id').fill(id);

  await reviewAndStart(page);
  await expect(page.getByTestId('start-result')).toBeVisible();
  await expect(page.getByTestId('start-result-link')).toHaveText(id);

  await page.getByTestId('start-done-btn').click();
  await expect(page.getByTestId('start-modal')).toHaveCount(0);

  return factory;
}

/** Opens the start flow from the screen's start control. */
export async function openStart(page: Page): Promise<void> {
  await page.getByTestId('start-relay-btn').click();
  await expect(page.getByTestId('start-modal')).toBeVisible();
}

/** Chooses `factory` in the open start flow, which moves on to its details. */
export async function chooseFactory(page: Page, factory: string): Promise<void> {
  await page.getByTestId(`factory-choice-${factory}`).click();
  await expect(page.getByTestId('input-relay-id')).toBeVisible();
}

/** From the details, on to the review and the start. */
export async function reviewAndStart(page: Page): Promise<void> {
  await page.getByTestId('start-next-btn').click();
  await expect(page.getByTestId('start-review')).toBeVisible();
  // One fact per line: what, where, under which id, served by whom, with what.
  for (const fact of ['review-factory', 'review-namespace', 'review-id', 'review-init-values']) {
    await expect(page.getByTestId(fact)).not.toBeEmpty();
  }
  await page.getByTestId('start-submit-btn').click();
}

async function preferredFactory(page: Page, run: Run): Promise<string> {
  const options = await factoryOptions(page);

  expect(options.length, 'at least one factory must be available').toBeGreaterThan(0);

  const seeded = SEEDED_FACTORY[run];
  return options.includes(seeded) ? seeded : options[0];
}

/**
 * Runs one of a row's actions: opens the row's menu, named by its test id,
 * and clicks the item. A row keeps its actions in a menu, so an item is
 * hidden until its menu opens.
 */
export async function menuAction(page: Page, menu: string, item: string): Promise<void> {
  await page.getByTestId(menu).click();
  await page.getByTestId(item).click();
}

/**
 * Stops `id` from its namespace's relays listing, which it opens itself.
 *
 * Tolerating an already-stopped relay is what makes this safe to call from
 * `finally` after the test stopped it itself; it never skips an assertion.
 */
export async function stopRelay(page: Page, id: string, namespace = 'default'): Promise<void> {
  await visitLive(page, `/namespaces/${namespace}/relays`);
  const row = page.getByTestId(`relay-index-row-${id}`);
  if ((await row.count()) === 0) return;

  await menuAction(page, `relay-menu-${id}`, `stop-relay-${id}`);
  await expect(page.getByTestId('stop-confirm-modal')).toBeVisible();
  await page.getByTestId('stop-confirm-btn').click();
  await expect(row).toHaveCount(0);
}

/**
 * Chooses `value` in a combobox, named by its trigger's test id.
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
 * The hidden input a combobox submits under, so a spec can assert on what it
 * currently holds with `toHaveValue`.
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
  const body = page.getByTestId(`section-body-${key}`);
  await expect(toggle).toBeVisible();

  // Checked against the toggle's own state each round, so a click that did not
  // take is made again rather than waited out, and one that did is not undone.
  await expect(async () => {
    if ((await toggle.getAttribute('aria-expanded')) !== String(open)) await toggle.click();
    await (open
      ? expect(body).toBeVisible({ timeout: 2_000 })
      : expect(body).toHaveCount(0, { timeout: 2_000 }));
  }).toPass({ timeout: 4_000 });
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
  // Always in the topbar, never behind a menu.
  await page.locator('.flz-topbar [data-testid="theme-toggle"]').click();
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
 * Cleanup, so a failure does not leave a cron job armed. Opens the schedules
 * screen itself, since a failed test may have left the page anywhere.
 *
 * Tolerating an already-removed schedule is what makes this safe to call from
 * `finally` after the test removed it itself; it never skips an assertion.
 */
export async function removeSchedule(page: Page, name: string): Promise<void> {
  await visitLive(page, '/schedules');
  const row = page.getByTestId(`schedule-row-${name}`);
  if ((await row.count()) === 0) return;

  await menuAction(page, `schedule-menu-${name}`, `schedule-remove-${name}`);
  await page.getByTestId('schedule-remove-confirm').click();
  await expect(row).toHaveCount(0);
}

/** What a test fills into the plugin form; anything left out stays blank. */
export type PluginFields = {
  provider: string;
  name?: string;
  relay?: string;
  hooks?: readonly string[];
  opts?: Record<string, string>;
};

/**
 * Opens the plugin form with the `opener` button — the relay screen's
 * `attach-plugin-btn` or the plugins screen's `enable-plugin-btn` — picks the
 * provider and fills `fields`: each option typed into its own field, a
 * selection chosen by its value. Leaves the form open and unsubmitted.
 */
export async function fillPluginForm(page: Page, opener: string, fields: PluginFields): Promise<void> {
  await page.getByTestId(opener).click();
  await expect(page.getByTestId('provider-grid')).toBeVisible();
  await page.getByTestId(`provider-btn-${fields.provider}`).click();
  await expect(page.getByTestId('input-plugin-name')).toBeVisible();

  if (fields.name) await page.getByTestId('input-plugin-name').fill(fields.name);
  if (fields.relay) await page.getByTestId('input-plugin-relay').selectOption(fields.relay);
  for (const hook of fields.hooks ?? []) await page.getByTestId(`input-hook-${hook}`).check();

  for (const [option, value] of Object.entries(fields.opts ?? {})) {
    const field = page.getByTestId(`input-option-${option}`);
    if ((await field.evaluate((el) => el.tagName)) === 'SELECT') await field.selectOption(value);
    else await field.fill(value);
  }
}

/** The error shown on a plugin option's field, inside the field's own container. */
export const optionError = (page: Page, option: string) =>
  page.getByTestId(`input-option-${option}`).locator('xpath=..').locator('.fui-error');

/**
 * Unbinds `name` from every relay and then disables it, from the plugins
 * screen. A disabled plugin keeps its bindings, and the controller keeps
 * trying to start them, so disabling alone would leave state behind.
 * Safe to call from `finally`: a plugin already gone is left alone.
 */
export async function disablePlugin(page: Page, name: string): Promise<void> {
  await visitLive(page, '/namespaces/default/plugins');
  const row = page.getByTestId(`plugin-row-${name}`);
  if ((await row.count()) === 0) return;

  await confirmEach(
    page,
    page.locator(`[data-testid^="plugin-unbind-${name}-"]`),
    'plugin-unbind-confirm',
    `plugin-menu-${name}`,
  );

  await menuAction(page, `plugin-menu-${name}`, `plugin-disable-${name}`);
  await page.getByTestId('plugin-disable-confirm').click();
  await expect(row).toHaveCount(0);
}

/**
 * Opens the settings screen, by address or by `open` — following a link to it.
 * Settings sits behind sudo mode, whose window is shorter than a full suite
 * run, so this re-authenticates as the worker's user rather than trusting its
 * stored session. The
 * email field is readonly on the re-auth form — only the password is asked for.
 */
export async function openSettings(
  page: Page,
  open: () => Promise<unknown> = () => page.goto('/users/settings'),
): Promise<void> {
  await open();
  await page.waitForURL(/\/users\/(settings|log-in)$/);

  if (page.url().includes('/users/log-in')) {
    await submitLogin(page, { password: workerUser(base.info().parallelIndex).password });
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
    await expect(page.getByTestId('flezha-token-binding')).toContainText('the service token is used');
  }
}

const UNIT_FACTOR: Record<string, number> = { B: 1, KB: 1_024, MB: 1_048_576 };

/** The first number a figure shows, scaled by its byte unit when it has one. */
export async function readFigure(figure: Locator): Promise<number> {
  const text = (await figure.textContent()) ?? '';
  const found = text.match(/(-?\d[\d,]*(?:\.\d+)?)\s*(MB|KB|B)?\b/);
  if (!found) throw new Error(`no number in "${text}"`);

  return parseFloat(found[1].replace(/,/g, '')) * (UNIT_FACTOR[found[2] ?? 'B'] ?? 1);
}

/**
 * Asserts `figure` grows past its current value once `cause` — the traffic or
 * action the test makes — has run. A figure is a number shown on the page, or
 * a function reading one, such as a count of rows. Returns as soon as it
 * grows, and names the figure when it does not.
 */
export async function expectAdvances(
  figure: Locator | (() => Promise<number>),
  name: string,
  cause: () => Promise<void> | void,
): Promise<number> {
  const read = typeof figure === 'function' ? figure : () => readFigure(figure);
  const before = await read();
  await cause();

  let after = before;
  await expect
    .poll(async () => (after = await read()), { message: `${name} did not advance from ${before}` })
    .toBeGreaterThan(before);

  return after;
}

/**
 * A page signed in as the worker's user, for a `beforeAll` or `afterAll`,
 * which get no `page` of their own. The caller closes its context.
 */
export async function workerPage(browser: Browser, testInfo: TestInfo): Promise<Page> {
  const context = await browser.newContext({
    baseURL: testInfo.project.use.baseURL,
    storageState: workerState(testInfo.parallelIndex),
  });
  return context.newPage();
}

/**
 * A relay of the spec file's own, under a run-unique id: started from the
 * namespace screen in `beforeAll` and stopped in `afterAll`, so every test in
 * the file can assert on it without another worker's traffic reaching it.
 */
export function ownRelay(prefix: string, opts: { run?: Run; factory?: string } = {}): { readonly id: string } {
  const id = uniqueId(prefix);
  let admin: Page;

  test.beforeAll(async ({ browser }, testInfo) => {
    admin = await workerPage(browser, testInfo);
    await visitLive(admin, '/namespaces/default');
    await startRelay(admin, id, opts);
  });

  test.afterAll(async () => {
    await stopRelay(admin, id);
    await admin.context().close();
  });

  return { id };
}

/** Opens `path` in a second page of the same session, beside the one under test. */
export async function openPage(page: Page, path: string): Promise<Page> {
  const other = await page.context().newPage();
  await visitLive(other, path);
  return other;
}

/**
 * Drives each control `controls` matches through its confirmation dialog,
 * until none is left, opening `menu` first when the controls sit in a row's
 * menu. For cleanup, where each confirmed action removes the control.
 */
export async function confirmEach(
  page: Page,
  controls: Locator,
  confirm: string,
  menu?: string,
): Promise<void> {
  while ((await controls.count()) > 0) {
    const before = await controls.count();
    if (menu) await page.getByTestId(menu).click();
    await controls.first().click();
    await page.getByTestId(confirm).click();
    await expect(controls).toHaveCount(before - 1);
  }
}

/**
 * Sends `payload` to the relay whose screen `page` shows, through the Talk
 * dialog's raw send, and closes the dialog once the controller took it.
 */
export async function sendToRelay(page: Page, payload: string, opts: { channel?: string; key?: string; msgId?: string } = {}): Promise<void> {
  await page.getByTestId('talk-open-btn').click();
  await page.getByTestId('talk-mode-raw').click();
  await page.getByTestId('talk-payload').fill(payload);
  if (opts.channel) await page.getByTestId('talk-channel').fill(opts.channel);
  if (opts.key) await page.getByTestId('talk-key').fill(opts.key);
  if (opts.msgId) await page.getByTestId('talk-msg-id').fill(opts.msgId);
  await page.getByTestId('talk-send-btn').click();
  await expect(page.getByTestId('talk-result').first()).toContainText('Delivered to');
  await page.getByTestId('talk-close-btn').click();
}

/** How many ticks the pipeline's timeline holds. */
export async function timelineSamples(page: Page): Promise<number> {
  const timeline = page.getByTestId('topology-timeline');
  if ((await timeline.count()) === 0) return 0;
  return Number((await timeline.getAttribute('data-samples')) ?? 0);
}

/** A page-health problem that is benign, matched against the reported line. */
export type PageHealthExemption = { match: RegExp; reason: string };

/**
 * Problems every test may meet without failing, each with why it is benign.
 * A test that provokes a problem on purpose allows it itself, through
 * `pageHealth.allow`.
 */
export const PAGE_HEALTH_EXEMPTIONS: readonly PageHealthExemption[] = [
  {
    match: /^no answer for .*: net::ERR_ABORTED /,
    reason: 'a navigation or a closing page cancels the requests still in flight',
  },
];

function assertReasons(exemptions: readonly PageHealthExemption[]): void {
  for (const { match, reason } of exemptions) {
    if (!reason?.trim()) throw new Error(`page-health exemption ${match} has no reason`);
  }
}

assertReasons(PAGE_HEALTH_EXEMPTIONS);

/** What a test can tell the page-health guards. */
export type PageHealth = {
  /** Allows problems matching `match` for this test only, saying why. */
  allow(match: RegExp, reason: string): void;
};

// Resource types whose failure the operator would see: a page, its code, its
// styling, a logo or font, or a request the page itself makes.
const GUARDED_RESOURCES = new Set(['document', 'script', 'stylesheet', 'image', 'font', 'xhr', 'fetch']);

const LIVEVIEW_ERROR_CLASSES = ['phx-error', 'phx-client-error', 'phx-server-error'];

/**
 * Reports a LiveView container that takes an error class. A crashed LiveView
 * re-joins the same container and drops the class again, so only watching the
 * class arrive records that it crashed.
 */
function watchLiveViewClasses(classes: string[]): void {
  new MutationObserver((mutations) => {
    for (const { target } of mutations) {
      const el = target as Element;
      if (!el.hasAttribute?.('data-phx-session')) continue;

      for (const cls of classes) {
        if (el.classList.contains(cls)) {
          (window as unknown as { __flzPageHealth: (line: string) => void }).__flzPageHealth(
            `LiveView ${el.id} took ${cls}`,
          );
        }
      }
    }
  }).observe(document, { subtree: true, attributes: true, attributeFilter: ['class'] });
}

/**
 * A LiveView frame that reports a crash or a refused join. A join answered
 * with a redirect is LiveView navigating, not an error.
 */
function liveViewFrameProblem(payload: string | Buffer): string | null {
  let frame: unknown;
  try {
    frame = JSON.parse(payload.toString());
  } catch {
    return null;
  }
  if (!Array.isArray(frame)) return null;

  const [, , topic, event, body] = frame as [unknown, unknown, string, string, any];
  if (typeof topic !== 'string' || !topic.startsWith('lv:')) return null;

  if (event === 'phx_error') return `LiveView ${topic} crashed`;

  if (event === 'phx_reply' && body?.status === 'error') {
    const response = body.response ?? {};
    if (response.redirect || response.live_redirect) return null;
    return `LiveView ${topic} answered an error: ${JSON.stringify(response)}`;
  }

  return null;
}

/**
 * `test` with a `live` helper bound to the page, so a spec reads
 * `await live('/audit')` instead of repeating the connect wait everywhere.
 *
 * Every test is also armed with page-health guards it cannot opt out of: a
 * script error or console error, a LiveView that crashes, errors or loses its
 * socket, and a request answered 400 or above or never answered each fail the
 * test at teardown, whatever it asserted.
 */
export const test = base.extend<{ live: (path: string) => Promise<void>; pageHealth: PageHealth }>({
  // A project naming its own session keeps it; every other test runs as its
  // worker's user, so per-user state never crosses workers.
  storageState: async ({ storageState }, use, testInfo) => {
    await use(storageState ?? workerState(testInfo.parallelIndex));
  },

  live: async ({ page }, use) => {
    await use((path: string) => visitLive(page, path));
  },

  pageHealth: [
    async ({ context, page }, use) => {
      const problems: string[] = [];
      const allowed: PageHealthExemption[] = [...PAGE_HEALTH_EXEMPTIONS];
      const report = (line: string) => problems.push(line);

      await context.exposeBinding('__flzPageHealth', ({ page: from }, line: string) =>
        report(`${line} (at ${from.url()})`),
      );
      await context.addInitScript(watchLiveViewClasses, LIVEVIEW_ERROR_CLASSES);

      const watch = (p: Page) => {
        p.on('pageerror', (error) => report(`script error: ${error.message} (at ${p.url()})`));

        p.on('console', (message) => {
          if (message.type() === 'error') report(`console error: ${message.text()} (at ${p.url()})`);
        });

        p.on('websocket', (socket) => {
          socket.on('framereceived', ({ payload }) => {
            const problem = liveViewFrameProblem(payload);
            if (problem) report(`${problem} (at ${p.url()})`);
          });
        });

        p.on('response', (response) => {
          const request = response.request();
          if (response.status() >= 400 && GUARDED_RESOURCES.has(request.resourceType())) {
            report(`${response.status()} for ${request.method()} ${response.url()} (at ${p.url()})`);
          }
        });

        p.on('requestfailed', (request) => {
          if (!GUARDED_RESOURCES.has(request.resourceType())) return;
          report(`no answer for ${request.method()} ${request.url()}: ${request.failure()?.errorText} (at ${p.url()})`);
        });
      };

      watch(page);
      context.on('page', watch);

      await use({
        allow(match: RegExp, reason: string) {
          assertReasons([{ match, reason }]);
          allowed.push({ match, reason });
        },
      });

      const unexpected = [...new Set(problems)].filter(
        (line) => !allowed.some(({ match }) => match.test(line)),
      );
      expect(unexpected, `the page was not healthy:\n${unexpected.join('\n')}`).toEqual([]);
    },
    { auto: true },
  ],
});

export { expect } from '@playwright/test';
export type { Page } from '@playwright/test';
