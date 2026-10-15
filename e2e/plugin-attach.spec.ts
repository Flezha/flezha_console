import {
  menuAction,
  ownRelay,
  test,
  expect,
  disablePlugin,
  openSection,
  uniqueId,
  fillPluginForm,
  optionError,
  type PluginFields,
  type Page,
} from './fixtures';

/**
 * Enabling a plugin by name and binding it to a relay, from the relay screen,
 * and disabling it again, against a relay this file starts.
 *
 * One test per provider, so a provider that breaks fails under its own name
 * rather than disappearing into a summary that passes when any one provider
 * worked. The hooks offered, the option bounds and the listings are asserted
 * in `test/flezha_ui_web/live/plugin_live_test.exs`.
 */

const { id: RELAY } = ownRelay('pw_attach');
const RELAY_URL = `/namespaces/default/relays/${RELAY}`;


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
      { message: `${providerId} must attach` },
    )
    .toBe('attached');
}

test.describe('Plugin attachment', () => {
  test.beforeEach(async ({ page, live }) => {
    await live(RELAY_URL);
    // The bindings table is one of the relay screen's folded sections.
    await openSection(page, 'plugins');
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
        await expect(page.getByTestId(`plugin-relays-${name}`)).toContainText(RELAY);
      } finally {
        await disablePlugin(page, name);
      }
    });
  }

  test('the pipeline graph draws a bound plugin, and an unbind removes it and keeps the plugin', async ({
    page,
    live,
  }) => {
    const name = uniqueId('pw_gplug');

    try {
      const graph = page.getByTestId('topology-graph');
      await expect(graph.getByTestId('topo-node-relay')).toBeVisible();
      await expect(graph.locator(`[data-testid*="${name}"]`)).toHaveCount(0);

      await attachForm(page, { provider: 'relay_stdout', name, hooks: ['on_output'] });
      await page.getByTestId('attach-submit-btn').click();
      await expectAttachAccepted(page, 'relay_stdout');

      // The bound plugin joins the drawing on the next tick, on the relay.
      await expect(graph.getByTestId(`topo-node-plugin-${name}`)).toBeVisible();
      await expect(graph.locator(`[data-testid^="topo-wire-"][data-testid*="${name}"]`).first()).toBeAttached();
      await expect(graph.getByTestId('topo-node-relay')).toBeVisible();

      await openSection(page, 'plugins');
      await menuAction(page, `binding-menu-${name}`, `unbind-btn-${name}`);
      await expect(page.getByTestId('unbind-confirm-modal')).toContainText('stays enabled');
      await page.getByTestId('unbind-confirm-btn').click();
      await expect(page.locator('body')).toContainText(`${RELAY} unbound from plugin ${name}.`);
      await expect(page.getByTestId(`binding-row-${name}`)).toHaveCount(0);
      await expect(graph.locator(`[data-testid*="${name}"]`)).toHaveCount(0);

      await live('/namespaces/default/plugins');
      await expect(page.getByTestId(`plugin-row-${name}`)).toBeVisible();
      await expect(page.getByTestId(`plugin-relays-${name}`)).not.toContainText(RELAY);
    } finally {
      await disablePlugin(page, name);
    }
  });

  test("the controller's refusal of an option is shown on its field with its code", async ({ page }) => {
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
});
