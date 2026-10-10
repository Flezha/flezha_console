import {
  test,
  expect,
  disablePlugin,
  openSection,
  startRelay,
  stopRelay,
  testIds,
  uniqueId,
  fillPluginForm,
  optionError,
  type PluginFields,
  type Page,
} from './fixtures';

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
  /** The provider's options, by name, as typed into each option's field. */
  opts: Record<string, string>;
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

/** The plugin ids of the binding rows currently in the table. */
const bindingIds = (page: Page) => testIds(page, 'binding-row-');

/** Fills the plugin form from the relay screen's Attach button. */
const attachForm = (page: Page, fields: PluginFields) => fillPluginForm(page, 'attach-plugin-btn', fields);

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
      const name = uniqueId('pw_plugin');

      try {
        await attachForm(page, { provider: id, name, hooks, opts });

        await page.getByTestId('attach-submit-btn').click();
        await expectAttachAccepted(page, id);
        await expect(page.locator('body')).toContainText(`Plugin ${name} enabled`);

        // The plugin is listed in its namespace, bound to this relay.
        await live('/namespaces/default/plugins');
        await expect(page.getByTestId(`plugin-row-${name}`)).toBeVisible();
        await expect(page.getByTestId(`plugin-relays-${name}`)).toContainText('testnet_store_1');
      } finally {
        await disablePlugin(page, name);
      }
    });
  }

  test('the pipeline graph draws a relay this test started, before and after a bind', async ({
    page,
    live,
  }) => {
    const relay = uniqueId('pw_graph');
    const name = uniqueId('pw_gplug');

    await live('/namespaces/default');
    await startRelay(page, relay);

    try {
      await live(`/namespaces/default/relays/${relay}`);
      const graph = page.getByTestId('topology-graph');
      for (const node of ['ingest', relay, 'channel', 'output']) {
        await expect(graph.getByTestId(`topo-node-${node}`)).toBeVisible();
      }
      await expect(graph.locator(`[data-testid*="${name}"]`)).toHaveCount(0);

      await openSection(page, 'plugins');
      await attachForm(page, { provider: 'relay_stdout', name, hooks: ['on_output'] });
      await page.getByTestId('attach-submit-btn').click();
      await expectAttachAccepted(page, 'relay_stdout');

      // The bound plugin joins the drawing on the next tick, the chain intact.
      await expect(graph.locator(`[data-testid^="topo-node-"][data-testid*="${name}"]`)).toBeVisible({
        timeout: 15_000,
      });
      await expect(graph.locator(`[data-testid^="topo-edge-"][data-testid*="${name}"]`).first()).toBeAttached();
      await expect(graph.getByTestId(`topo-node-${relay}`)).toBeVisible();
      await expect(graph.getByTestId('topo-node-output')).toBeVisible();
    } finally {
      await disablePlugin(page, name);
      await live('/namespaces/default');
      await stopRelay(page, relay);
    }
  });

  test('only the hooks the provider supports are offered', async ({ page }) => {
    await attachForm(page, { provider: 'relay_stdout' });

    // Offered as checkboxes from the provider's own description, so there is
    // no free-text hook field to mistype.
    await expect(page.getByTestId('input-hooks')).toBeVisible();
    await expect(page.locator('input[name="plugin[hook]"]')).toHaveCount(0);

    await page.getByTestId('attach-cancel-btn').click();
  });

  test('an option outside its bounds is refused on its field', async ({ page }) => {
    const before = await bindingIds(page);

    await attachForm(page, {
      provider: 'relay_http_push',
      hooks: ['on_output'],
      opts: { url: 'http://fui_web:4000/dev/null', timeout_ms: '0' },
    });
    await page.getByTestId('attach-submit-btn').click();

    await expect(optionError(page, 'timeout_ms')).toContainText('must be at least 1');
    await expect(page.getByTestId('attach-error')).toHaveCount(0);
    await expect(page.getByTestId('attach-modal')).toBeVisible();

    await page.getByTestId('attach-cancel-btn').click();
    expect(await bindingIds(page)).toEqual(before);
  });

  test("the controller's refusal of an option is shown on its field with its code", async ({
    page,
    live,
  }) => {
    const name = uniqueId('pw_refused');

    try {
      await attachForm(page, {
        provider: 'hook_webhook',
        name,
        hooks: ['on_relay_started'],
        opts: { url: 'ftp://fui_web/x' },
      });
      await page.getByTestId('attach-submit-btn').click();

      await expect(optionError(page, 'url')).toContainText('(plugin.url_scheme_unsupported)');
      await expect(page.getByTestId('attach-modal')).toBeVisible();

      await page.getByTestId('attach-cancel-btn').click();
    } finally {
      await disablePlugin(page, name);
    }
  });

  test('unbinding from the relay screen removes the binding and leaves the plugin enabled', async ({
    page,
    live,
  }) => {
    const name = uniqueId('pw_unbind');

    try {
      await attachForm(page, { provider: 'relay_stdout', name, hooks: ['on_output'] });
      await page.getByTestId('attach-submit-btn').click();
      await expectAttachAccepted(page, 'relay_stdout');

      await openSection(page, 'plugins');
      await expect(page.getByTestId(`binding-row-${name}`)).toBeVisible();

      // Cancelling leaves the binding where it was.
      await page.getByTestId(`unbind-btn-${name}`).click();
      await expect(page.getByTestId('unbind-confirm-modal')).toContainText('stays enabled');
      await page.getByTestId('unbind-cancel-btn').click();
      await expect(page.getByTestId('unbind-confirm-modal')).toHaveCount(0);
      await expect(page.getByTestId(`binding-row-${name}`)).toBeVisible();

      await page.getByTestId(`unbind-btn-${name}`).click();
      await page.getByTestId('unbind-confirm-btn').click();
      await expect(page.locator('body')).toContainText(`testnet_store_1 unbound from plugin ${name}.`);
      await expect(page.getByTestId(`binding-row-${name}`)).toHaveCount(0);

      await live('/namespaces/default/plugins');
      await expect(page.getByTestId(`plugin-row-${name}`)).toBeVisible();
      await expect(page.getByTestId(`plugin-relays-${name}`)).not.toContainText('testnet_store_1');
    } finally {
      await disablePlugin(page, name);
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
