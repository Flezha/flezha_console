import { test, expect, testIds, type Page } from './fixtures';

/**
 * Attaching and detaching every plugin provider the controller offers.
 *
 * One test per provider, so a provider that breaks fails under its own name
 * rather than disappearing into a summary that passes when any one provider
 * worked.
 */

const OPERATIVE_URL = '/namespaces/default/operatives/testnet_store_1';

/** Position is meaningful only where the extension is an ordered chain. */
const ORDERED_EXTENSIONS = new Set(['on_input', 'on_output']);

interface ProviderCase {
  id: string;
  /** The extension the provider exports and can therefore be subscribed to. */
  trigger: string;
  /** Set when the dev stack cannot support the case at all. */
  skip?: string;
}

/**
 * Which extension each provider exports.
 *
 * The controller validates this: subscribing a provider to an extension it
 * does not export is refused with `{:missing_callback, …}` rather than
 * silently creating a plugin that never runs. Sources — websocket, http poll —
 * connect when enabled and export `on_terminate` for teardown, not `on_input`.
 */
const PROVIDERS: ReadonlyArray<ProviderCase> = [
  { id: 'operative_forward', trigger: 'on_input' },
  { id: 'operative_http_poll', trigger: 'on_terminate' },
  { id: 'operative_io_filter', trigger: 'on_input' },
  { id: 'operative_kafka_producer', trigger: 'on_input' },
  {
    id: 'operative_message_forward',
    trigger: 'on_input',
    skip:
      'the provider exports none of the extensions this UI offers — every one ' +
      'is refused with {:missing_callback, …}, so it cannot be attached here at all',
  },
  { id: 'operative_postgres', trigger: 'on_input' },
  { id: 'operative_stdout', trigger: 'on_input' },
  { id: 'operative_websocket', trigger: 'on_terminate' },
];

/**
 * Values that must point at real infrastructure rather than a plausible-looking
 * string.
 *
 * A plugin runs on the controller, inside the compose network — so it reaches
 * Kafka at `fui_kafka:9092` and Postgres at `flezha_ui_db:5432`, not at
 * `localhost`. Getting this wrong is what made these providers fail to attach
 * while the old suite reported green.
 */
const FIELD_OVERRIDES: Record<string, Record<string, string>> = {
  operative_kafka_producer: {
    hosts: 'fui_kafka:9092',
    topic: 'flezha_e2e_test',
  },
  operative_postgres: {
    hostname: 'flezha_ui_db',
    port: '5432',
    database: 'flezha_ui_db',
    username: 'postgres',
    password: 'postgres',
  },
  operative_http_poll: {
    // The UI itself is the one HTTP server guaranteed to be up.
    url: 'http://fui_web:4000/users/log-in',
  },
  operative_forward: {
    // Forwarding to the operative under test is refused as a self-target, so
    // this points at another operative the dev stack seeds.
    target_operative_id: 'testnet_store_2',
  },
};

/**
 * A plausible value for a provider config field, chosen by name.
 *
 * Several of these encode requirements learned from the providers themselves:
 * `ws_opts` is passed to `Keyword.get` so it must be a list, `payload_metadata`
 * must be a map, and the filter's `inverted` is parsed from a string.
 */
function guessFieldValue(fieldName: string): string {
  const lower = fieldName.toLowerCase();
  // Boolean fields
  if (lower.includes('inverted') || lower.includes('enabled') || lower.includes('flag'))
    return 'false';
  // JSON object/array fields
  if (lower.includes('metadata')) return '{}';
  if (lower.includes('opts') || lower.includes('options')) return '[]';
  // URI/URL fields
  if (lower.includes('uri') || lower.includes('url')) return 'ws://localhost:9999/test';
  // Network fields
  if (lower.includes('hosts')) return 'localhost:9092';
  if (lower.includes('host')) return 'localhost';
  if (lower.includes('port')) return '9999';
  if (lower.includes('address')) return 'localhost:9999';
  // Path/file fields
  if (lower.includes('path')) return '/tmp/test';
  if (lower.includes('pattern') || lower.includes('regex')) return '.*';
  // Messaging fields
  if (lower.includes('topic')) return 'test-topic';
  if (lower.includes('channel')) return 'test-channel';
  if (lower.includes('queue')) return 'test-queue';
  // Numeric fields
  if (lower.includes('partition')) return '0';
  if (lower.includes('ack')) return '1';
  if (lower.includes('interval') || lower.includes('timeout')) return '5000';
  if (lower.includes('size') || lower.includes('count') || lower.includes('max')) return '100';
  // Name fields
  if (lower.includes('name')) return 'test_name';
  if (lower === 'conn' || lower === 'post_connect') return 'test';
  return 'test_value_123';
}

/** The plugin ids of the binding rows currently in the table. */
const bindingIds = (page: Page) => testIds(page, 'binding-row-');

/** Opens the attach modal and selects `providerId`, leaving the form shown. */
async function openConfigureForm(page: Page, providerId: string) {
  await page.getByTestId('attach-plugin-btn').click();
  await expect(page.getByTestId('provider-grid')).toBeVisible();
  await page.getByTestId(`provider-btn-${providerId}`).click();
  await expect(page.getByTestId('input-plugin-id')).toBeVisible();
}

/**
 * Fills the provider's *required* fields only.
 *
 * The optional ones are left blank on purpose: the UI turns a blank field into
 * `nil` so the provider's own default applies, and several of them are runtime
 * handles — `worker_pid`, `producer_pid`, `registry_ref` — that a caller must
 * not supply at all. Filling every rendered field is what made most of these
 * providers refuse to attach.
 */
async function fillProviderFields(page: Page, providerId: string) {
  const required = page.locator('[data-testid^="input-field-"][data-required="true"]');
  const overrides = FIELD_OVERRIDES[providerId] ?? {};

  for (const field of await required.all()) {
    const name = ((await field.getAttribute('data-testid')) ?? '').replace('input-field-', '');
    await field.fill(overrides[name] ?? guessFieldValue(name));
  }
}

/**
 * Waits for the attach to settle and asserts it succeeded.
 *
 * The modal closing is the success signal; a refusal keeps it open with the
 * controller's reason in `attach-error`. Polling for one or the other means a
 * failure reports *why* the controller said no, instead of "the modal did not
 * close".
 */
async function expectAttachAccepted(page: Page, providerId: string) {
  await expect
    .poll(
      async () => {
        if ((await page.getByTestId('attach-modal').count()) === 0) return 'attached';

        const error = page.getByTestId('attach-error');
        if ((await error.count()) === 0) return 'pending';
        return (await error.innerText()).trim();
      },
      { message: `${providerId} must attach`, timeout: 15_000 },
    )
    .toBe('attached');
}

async function detach(page: Page, pluginId: string) {
  await page.getByTestId(`detach-btn-${pluginId}`).click();
  await expect(page.getByTestId('detach-confirm-modal')).toBeVisible();
  await page.getByTestId('detach-confirm-btn').click();
  await expect(page.getByTestId(`binding-row-${pluginId}`)).toHaveCount(0);
}

test.describe('Plugin attachment', () => {
  test.beforeEach(async ({ live }) => {
    await live(OPERATIVE_URL);
  });

  test('discovers the providers the controller offers', async ({ page }) => {
    await page.getByTestId('attach-plugin-btn').click();
    await expect(page.getByTestId('attach-modal')).toBeVisible();
    await expect(page.getByTestId('provider-grid')).toBeVisible();

    const discovered = await testIds(page, 'provider-btn-');

    expect(discovered.length).toBeGreaterThan(0);
    // Every provider this suite has a test for must still be offered; a
    // provider that vanished would otherwise silently lose its coverage.
    for (const { id } of PROVIDERS) {
      expect(discovered, `${id} is no longer offered`).toContain(id);
    }

    await page.getByTestId('attach-close-btn').click();
    await expect(page.getByTestId('attach-modal')).toHaveCount(0);
  });

  for (const { id, trigger, skip } of PROVIDERS) {
    test(`attaches and detaches ${id}`, async ({ page }) => {
      test.skip(!!skip, skip);

      const before = await bindingIds(page);

      await openConfigureForm(page, id);
      await page.getByTestId('input-trigger').selectOption(trigger);
      if (ORDERED_EXTENSIONS.has(trigger)) {
        await page.getByTestId('input-position').fill('0');
      }
      await fillProviderFields(page, id);

      await page.getByTestId('attach-submit-btn').click();
      await expectAttachAccepted(page, id);

      const after = await bindingIds(page);
      const created = after.filter((pid) => !before.includes(pid));
      expect(created, 'attach must produce exactly one new binding row').toHaveLength(1);

      await detach(page, created[0]);
      expect(await bindingIds(page)).toEqual(before);
    });
  }

  test('position is refused on an extension that is not ordered', async ({ page }) => {
    // Position orders a chain, so offering it for a one-shot extension would
    // silently do nothing. The UI must say so rather than accept it.
    await openConfigureForm(page, 'operative_websocket');
    await page.getByTestId('input-field-uri').fill('ws://localhost:9999/test');
    await page.getByTestId('input-trigger').selectOption('on_terminate');
    await page.getByTestId('input-position').fill('0');
    await page.getByTestId('attach-submit-btn').click();

    await expect(page.getByTestId('attach-error')).toContainText('Position applies only to');
    await expect(page.getByTestId('attach-modal')).toBeVisible();

    await page.getByTestId('attach-cancel-btn').click();
  });

  test('refuses forwarding an operative to itself', async ({ page }) => {
    await openConfigureForm(page, 'operative_forward');
    await page.getByTestId('input-trigger').selectOption('on_input');
    await page.getByTestId('input-field-target_operative_id').fill('testnet_store_1');
    await page.getByTestId('attach-submit-btn').click();

    await expect(page.getByTestId('attach-error')).toContainText('is the operative itself');

    await page.getByTestId('attach-cancel-btn').click();
  });

  test('attaching stdout and detaching it reports both in the flash', async ({ page }) => {
    const before = await bindingIds(page);

    await openConfigureForm(page, 'operative_stdout');
    const pluginId = await page.getByTestId('input-plugin-id').inputValue();
    await page.getByTestId('input-trigger').selectOption('on_input');
    await page.getByTestId('attach-submit-btn').click();

    await expectAttachAccepted(page, 'operative_stdout');
    await expect(page.getByTestId(`binding-row-${pluginId}`)).toBeVisible();

    await detach(page, pluginId);

    await expect(page.locator('body')).toContainText('Plugin detached');
    await expect(page.locator('body')).not.toContainText('Failed:');
    expect(await bindingIds(page)).toEqual(before);
  });

  test('attaches the websocket provider on an extension it exports', async ({ page }) => {
    const before = await bindingIds(page);

    await openConfigureForm(page, 'operative_websocket');
    await page.getByTestId('input-field-uri').fill('ws://localhost:9999/test');
    await page.getByTestId('input-trigger').selectOption('on_terminate');
    await page.getByTestId('attach-submit-btn').click();

    await expectAttachAccepted(page, 'operative_websocket');

    const created = (await bindingIds(page)).filter((pid) => !before.includes(pid));
    expect(created).toHaveLength(1);

    const row = page.getByTestId(`binding-row-${created[0]}`);
    await expect(row).toContainText('Websocket');
    await expect(row).toContainText('on_terminate');

    await detach(page, created[0]);
    expect(await bindingIds(page)).toEqual(before);
  });

  test('refuses an extension the provider does not export', async ({ page }) => {
    // The extension table validates that the provider exports a callback for
    // every subscription. The websocket provider has no `on_input`, so this
    // must be reported rather than silently creating a plugin that never runs.
    const before = await bindingIds(page);

    await openConfigureForm(page, 'operative_websocket');
    await page.getByTestId('input-field-uri').fill('ws://localhost:9999/test');
    await page.getByTestId('input-trigger').selectOption('on_input');
    await page.getByTestId('attach-submit-btn').click();

    await expect(page.getByTestId('attach-error')).toContainText('missing_callback');
    await expect(page.getByTestId('attach-modal')).toBeVisible();

    await page.getByTestId('attach-cancel-btn').click();
    expect(await bindingIds(page), 'a refused plugin must not appear as a binding').toEqual(
      before,
    );
  });
});
