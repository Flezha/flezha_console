import { test, expect, openSection, testIds, type Page } from './fixtures';

/**
 * Enabling a plugin by name and binding it to a relay, from the relay screen,
 * and disabling it again.
 *
 * One test per provider, so a provider that breaks fails under its own name
 * rather than disappearing into a summary that passes when any one provider
 * worked.
 */

const RELAY_URL = '/namespaces/default/relays/testnet_store_1';

interface ProviderCase {
  id: string;
  /** The provider's options, as the JSON object the form takes. */
  opts: Record<string, unknown>;
  /**
   * The hooks to bind on, of those the provider offers. A source binds
   * `on_terminate` only to tear down; `on_interval` would need an interval.
   */
  hooks: ReadonlyArray<string>;
}

/**
 * The providers this suite drives end to end. Options point at real
 * infrastructure rather than a plausible-looking string: a plugin runs on the
 * controller, inside the compose network.
 */
const PROVIDERS: ReadonlyArray<ProviderCase> = [
  { id: 'relay_stdout', opts: {}, hooks: ['on_output'] },
  { id: 'relay_websocket', opts: { uri: 'ws://flezha_controller:4500' }, hooks: ['on_terminate'] },
];

/** Unique per test, so a leftover from a failed run cannot collide. */
function uniquePluginName(prefix = 'pw_plugin'): string {
  const ts = Date.now().toString(36).slice(-4);
  const rand = Math.random().toString(36).slice(2, 5);
  return `${prefix}_${ts}_${rand}`;
}

/** The plugin ids of the binding rows currently in the table. */
const bindingIds = (page: Page) => testIds(page, 'binding-row-');

/** Opens the attach modal and selects `providerId`, leaving the form shown. */
async function openConfigureForm(page: Page, providerId: string) {
  await page.getByTestId('attach-plugin-btn').click();
  await expect(page.getByTestId('provider-grid')).toBeVisible();
  await page.getByTestId(`provider-btn-${providerId}`).click();
  await expect(page.getByTestId('input-plugin-name')).toBeVisible();
}

/** Ticks every hook the provider offers, which is what binds it on the record path. */
async function chooseHooks(page: Page, hooks: ReadonlyArray<string> = ['on_output']) {
  for (const hook of hooks) {
    await page.getByTestId(`input-hook-${hook}`).check();
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

/** Disables `name` from the relay screen's bindings panel. */
async function disableFromRelay(page: Page, name: string) {
  await page.getByTestId(`detach-btn-${name}`).click();
  await expect(page.getByTestId('detach-confirm-modal')).toBeVisible();
  await page.getByTestId('detach-confirm-btn').click();
  await expect(page.locator('body')).toContainText(`Plugin ${name} disabled`);
}

/**
 * Disables `name` from the plugins screen, whatever the relay screen shows.
 * Safe to call from `finally`: a plugin already gone is left alone.
 */
async function disableEverywhere(page: Page, live: (path: string) => Promise<void>, name: string) {
  await live('/namespaces/default/plugins');
  const row = page.getByTestId(`plugin-row-${name}`);
  if ((await row.count()) === 0) return;

  await page.getByTestId(`plugin-disable-${name}`).click();
  await page.getByTestId('plugin-disable-confirm').click();
  await expect(row).toHaveCount(0);
}

test.describe('Plugin attachment', () => {
  test.beforeEach(async ({ page, live }) => {
    await live(RELAY_URL);
    // The bindings table is one of the relay screen's folded sections.
    await openSection(page, 'plugins');
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

  for (const { id, opts, hooks } of PROVIDERS) {
    test(`enables ${id} by name, binds it to the relay, and disables it`, async ({
      page,
      live,
    }) => {
      const name = uniquePluginName();

      try {
        await openConfigureForm(page, id);
        await page.getByTestId('input-plugin-name').fill(name);
        await chooseHooks(page, hooks);
        await page.getByTestId('input-plugin-opts').fill(JSON.stringify(opts));

        await page.getByTestId('attach-submit-btn').click();
        await expectAttachAccepted(page, id);
        await expect(page.locator('body')).toContainText(`Plugin ${name} enabled`);

        // The plugin is listed in its namespace, bound to this relay.
        await live('/namespaces/default/plugins');
        await expect(page.getByTestId(`plugin-row-${name}`)).toBeVisible();
        await expect(page.getByTestId(`plugin-relays-${name}`)).toContainText('testnet_store_1');
      } finally {
        await disableEverywhere(page, live, name);
      }
    });
  }

  test('only the hooks the provider supports are offered', async ({ page }) => {
    await openConfigureForm(page, 'relay_stdout');

    // Offered as checkboxes from the provider's own description, so there is
    // no free-text hook field to mistype.
    await expect(page.getByTestId('input-hooks')).toBeVisible();
    await expect(page.locator('input[name="plugin[hook]"]')).toHaveCount(0);

    await page.getByTestId('attach-cancel-btn').click();
  });

  test('options that are not a JSON object are refused on the form', async ({ page }) => {
    const before = await bindingIds(page);

    await openConfigureForm(page, 'relay_stdout');
    await page.getByTestId('input-plugin-opts').fill('[1, 2]');
    await page.getByTestId('attach-submit-btn').click();

    await expect(page.getByTestId('attach-error')).toContainText('JSON object');
    await expect(page.getByTestId('attach-modal')).toBeVisible();

    await page.getByTestId('attach-cancel-btn').click();
    expect(await bindingIds(page)).toEqual(before);
  });

  test("the controller's refusal is shown on the form with its code", async ({ page, live }) => {
    const name = uniquePluginName('pw_refused');

    try {
      await openConfigureForm(page, 'relay_stdout');
      await page.getByTestId('input-plugin-name').fill(name);
      await chooseHooks(page);
      await page.getByTestId('input-plugin-opts').fill('{"no_such_option": 1}');
      await page.getByTestId('attach-submit-btn').click();

      await expect(page.getByTestId('attach-error')).toContainText('plugin.');
      await expect(page.getByTestId('attach-modal')).toBeVisible();

      await page.getByTestId('attach-cancel-btn').click();
    } finally {
      await disableEverywhere(page, live, name);
    }
  });

  test('disabling from the relay screen reports it in the flash', async ({ page, live }) => {
    const name = uniquePluginName('pw_disable');

    try {
      await openConfigureForm(page, 'relay_stdout');
      await page.getByTestId('input-plugin-name').fill(name);
      await chooseHooks(page);
      await page.getByTestId('attach-submit-btn').click();
      await expectAttachAccepted(page, 'relay_stdout');

      await openSection(page, 'plugins');
      await expect(page.getByTestId(`binding-row-${name}`)).toBeVisible();

      await disableFromRelay(page, name);
      await expect(page.getByTestId('runtime-error')).toHaveCount(0);
    } finally {
      await disableEverywhere(page, live, name);
    }
  });
});

/**
 * The catalog of what is installed on the controller host, which is a
 * different list from the plugins enabled in a namespace.
 */
test.describe('Installed-plugin catalog', () => {
  test('renders separately from the enabled plugins, with no installer controls', async ({
    page,
    live,
  }) => {
    await live('/plugins');

    const catalog = page.getByTestId('installed-catalog');
    await expect(catalog).toBeVisible();
    // Installing is a deploy action, named rather than offered.
    await expect(catalog).toContainText('flz plugin');

    await expect(page.locator('[phx-click="install_plugin"]')).toHaveCount(0);
    await expect(page.locator('[phx-click="uninstall_plugin"]')).toHaveCount(0);
    await expect(page.locator('[phx-click="upgrade_plugin"]')).toHaveCount(0);
  });

  test('lists the seeded plugins with the relay each is bound to', async ({ page, live }) => {
    await live('/plugins');

    await expect(page.getByTestId('plugin-row-ws_store_1')).toBeVisible();
    await expect(page.getByTestId('plugin-relays-ws_store_1')).toContainText('testnet_store_1');
  });
});
