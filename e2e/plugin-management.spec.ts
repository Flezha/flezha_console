import {
  openSection,
  menuAction,
  test,
  expect,
  disablePlugin,
  fillPluginForm,
  optionError,
  uniqueId,
  type Page,
} from './fixtures';

/**
 * The plugin packages the controller holds and the plugin writes made from the
 * plugins screen: a controller plugin enabled with controller hooks, and a
 * relay plugin bound to a further relay, unbound and given new options.
 *
 * The dev stack places two packages before the controller boots
 * (`priv/dev/plugin_packages.sh`): `flezha_http`, which loads, and
 * `flezha_http_tampered`, whose manifest changed after it was checksummed,
 * which the loader refuses. Every plugin a test enables it disables in
 * `finally`. No dev provider declares a transient option, so the password
 * field it gets is asserted in `test/flezha_ui_web/live/plugin_live_test.exs`.
 */
const PLUGINS_URL = '/namespaces/default/plugins';

/** Fills the plugin form from the plugins screen and submits it. */
async function fillEnable(
  page: Page,
  name: string,
  provider: string,
  hooks: string[],
  opts: Record<string, string>,
  relay?: string,
) {
  await fillPluginForm(page, 'enable-plugin-btn', { provider, name, relay, hooks, opts });
  await page.getByTestId('attach-submit-btn').click();
}

/** Enables `name` as `fillEnable` does, and asserts the dialog closed on success. */
async function enable(
  page: Page,
  name: string,
  provider: string,
  hooks: string[],
  opts: Record<string, string>,
  relay?: string,
) {
  await fillEnable(page, name, provider, hooks, opts, relay);
  await expect(page.getByTestId('attach-modal')).toHaveCount(0);
}

/** The hint shown on an option's field. */
const optionHint = (page: Page, option: string) =>
  page.getByTestId(`input-option-${option}`).locator('xpath=..').locator('.fui-hint');

const RECEIVER = 'http://fui_web:4000/dev/null';

test.describe('Plugin packages', () => {
  test.beforeEach(async ({ live }) => {
    await live(PLUGINS_URL);
  });

  test('the loaded package lists its providers', async ({ page }) => {
    await expect(page.getByTestId('installed-status-flezha_http')).toHaveText(/Loaded/);
    await expect(page.getByTestId('installed-providers-flezha_http')).toContainText('http_server');
  });

  test('the refused package explains itself and its count is stated', async ({ page }) => {
    await expect(page.getByTestId('installed-status-flezha_http_tampered')).toHaveText(/Refused/);

    const error = page.getByTestId('installed-error-flezha_http_tampered');
    await expect(error).toContainText(/\(plugin\.[a-z_]+\)/);
    await expect(error.getByTestId('runtime-error-reference')).toHaveAttribute(
      'href',
      /\/errors\.html#plugin$/,
    );

    await openSection(page, 'providers');
    await expect(page.getByTestId('providers-refused')).toContainText('refused 1 installed package');
  });
});

test.describe('Enabled plugins', () => {
  test.beforeEach(async ({ live }) => {
    await live(PLUGINS_URL);
  });

  test('the seeded controller plugin states its hooks and where it runs', async ({ page }) => {
    const row = page.getByTestId('plugin-row-lifecycle_webhook');
    await expect(row).toContainText('on_relay_started');
    await expect(row).toContainText('on_relay_stopped');
    await expect(page.getByTestId('plugin-relays-lifecycle_webhook')).toHaveText(/^\s*—\s*$/);
    await expect(page.getByTestId('plugin-controllers-lifecycle_webhook')).toContainText('flezha@');
    // One controller serves the namespace, so none lags behind it.
    await expect(page.getByTestId('plugin-lagging-lifecycle_webhook')).toHaveCount(0);
  });

  test('cancelling a disable leaves the plugin enabled and bound', async ({ page }) => {
    await menuAction(page, 'plugin-menu-ws_store_1', 'plugin-disable-ws_store_1');
    await expect(page.getByTestId('plugin-disable-modal')).toContainText('ws_store_1');
    await page.getByTestId('plugin-disable-cancel').click();

    await expect(page.getByTestId('plugin-disable-modal')).toHaveCount(0);
    await expect(page.getByTestId('plugin-relays-ws_store_1')).toContainText('testnet_store_1');
  });

  test('cancelling an unbind leaves the relay bound', async ({ page }) => {
    await menuAction(page, 'plugin-menu-ws_store_1', 'plugin-unbind-ws_store_1-testnet_store_1');
    await expect(page.getByTestId('plugin-unbind-modal')).toContainText('stays enabled');
    await page.getByTestId('plugin-unbind-cancel').click();

    await expect(page.getByTestId('plugin-unbind-modal')).toHaveCount(0);
    await expect(page.getByTestId('plugin-relays-ws_store_1')).toContainText('testnet_store_1');
  });
});

test.describe('Plugin writes', () => {
  test.beforeEach(async ({ live }) => {
    await live(PLUGINS_URL);
  });

  test('a controller plugin is enabled with controller hooks and no relay', async ({
    page,
    live,
  }) => {
    const name = uniqueId('pw_hooks');

    try {
      await page.getByTestId('enable-plugin-btn').click();
      await page.getByTestId('provider-btn-hook_webhook').click();

      // A controller plugin runs on controllers, so no relay is asked for.
      await expect(page.getByTestId('input-plugin-relay')).toHaveCount(0);
      await expect(page.getByTestId('input-plugin-single')).toBeVisible();

      await page.getByTestId('input-plugin-name').fill(name);
      await page.getByTestId('input-hook-on_relay_started').check();
      await page.getByTestId('input-option-url').fill(RECEIVER);
      await page.getByTestId('attach-submit-btn').click();

      // One controller holds the namespace, so none lacks the provider.
      await expect(page.locator('body')).toContainText(`Plugin ${name} enabled.`);
      await expect(page.locator('body')).not.toContainText('does not run on');

      const row = page.getByTestId(`plugin-row-${name}`);
      await expect(row).toContainText('on_relay_started');
      await expect(page.getByTestId(`plugin-controllers-${name}`)).toContainText('flezha@');
      await expect(page.getByTestId(`plugin-bind-${name}`)).toHaveCount(0);
    } finally {
      await disablePlugin(page, name);
    }
  });

  test('a relay plugin is bound to a further relay, unbound and updated', async ({
    page,
    live,
  }) => {
    const name = uniqueId('pw_out');

    try {
      await enable(page, name, 'relay_stdout', ['on_output'], {}, 'testnet_store_1');
      await expect(page.getByTestId(`plugin-relays-${name}`)).toContainText('testnet_store_1');

      // Bind
      await menuAction(page, `plugin-menu-${name}`, `plugin-bind-${name}`);
      await page.getByTestId('input-plugin-relay').selectOption('testnet_store_2');
      await page.getByTestId('input-hook-on_output').check();
      await page.getByTestId('attach-submit-btn').click();
      await expect(page.locator('body')).toContainText(`Plugin ${name} bound to testnet_store_2.`);
      await expect(page.getByTestId(`plugin-relays-${name}`)).toContainText('testnet_store_2');

      // Unbind, after a confirmation
      await menuAction(page, `plugin-menu-${name}`, `plugin-unbind-${name}-testnet_store_2`);
      await expect(page.getByTestId('plugin-unbind-modal')).toContainText('stays enabled');
      await page.getByTestId('plugin-unbind-confirm').click();
      await expect(page.getByTestId(`plugin-relays-${name}`)).not.toContainText('testnet_store_2');
      await expect(page.getByTestId(`plugin-row-${name}`)).toBeVisible();

      // Update, with nothing filled in
      await menuAction(page, `plugin-menu-${name}`, `plugin-update-${name}`);
      await expect(page.getByTestId('plugin-no-options')).toBeVisible();
      await page.getByTestId('attach-submit-btn').click();
      await expect(page.locator('body')).toContainText(
        new RegExp(`Plugin ${name} updated: (applied live|applied by restarting its copies|nothing changed)\\.`),
      );
    } finally {
      await disablePlugin(page, name);
    }
  });

  test('relay_http_push is enabled with typed options', async ({ page }) => {
    const name = uniqueId('pw_push');

    try {
      await enable(
        page,
        name,
        'relay_http_push',
        ['on_output'],
        {
          url: RECEIVER,
          method: 'PUT',
          headers: '{"x-test": "1"}',
          channel: 'a, b',
          timeout_ms: '2000',
        },
        'testnet_store_1',
      );

      await expect(page.locator('body')).toContainText(`Plugin ${name} enabled and bound to testnet_store_1.`);
      await expect(page.getByTestId(`plugin-row-${name}`)).toBeVisible();
    } finally {
      await disablePlugin(page, name);
    }
  });

  test('relay_io_filter is enabled with a true/false option', async ({ page }) => {
    const name = uniqueId('pw_filter');

    try {
      // Inverted, a pattern nothing matches skips nothing on the shared relay.
      await enable(
        page,
        name,
        'relay_io_filter',
        ['on_output'],
        { regex_pattern: '^pw-never-matches$', inverted: 'true' },
        'testnet_store_1',
      );

      await expect(page.getByTestId(`plugin-row-${name}`)).toBeVisible();
    } finally {
      await disablePlugin(page, name);
    }
  });

  test('hook_webhook is updated with one option, which restarts its copies', async ({ page }) => {
    const name = uniqueId('pw_webhook');

    try {
      await enable(page, name, 'hook_webhook', ['on_relay_started'], { url: RECEIVER });
      await expect(page.getByTestId(`plugin-row-${name}`)).toBeVisible();

      await menuAction(page, `plugin-menu-${name}`, `plugin-update-${name}`);
      await expect(optionHint(page, 'timeout_ms')).toContainText('a change restarts the plugin');
      await page.getByTestId('input-option-timeout_ms').fill('7000');
      await page.getByTestId('attach-submit-btn').click();

      await expect(page.locator('body')).toContainText(
        `Plugin ${name} updated: applied by restarting its copies.`,
      );
    } finally {
      await disablePlugin(page, name);
    }
  });

  test('a number past its bound and JSON that does not parse are named on their fields', async ({
    page,
  }) => {
    const name = uniqueId('pw_bounds');

    try {
      await fillEnable(page, name, 'hook_webhook', ['on_relay_started'], {
        url: RECEIVER,
        timeout_ms: '70000',
        headers: '{not json',
      });

      await expect(optionError(page, 'timeout_ms')).toContainText('60000');
      await expect(optionError(page, 'headers')).toBeVisible();
      await expect(page.getByTestId('attach-modal')).toBeVisible();

      // Fixed, the same form enables the plugin.
      await page.getByTestId('input-option-timeout_ms').fill('7000');
      await page.getByTestId('input-option-headers').fill('{"x-test": "1"}');
      await page.getByTestId('attach-submit-btn').click();
      await expect(page.getByTestId('attach-modal')).toHaveCount(0);
      await expect(page.getByTestId(`plugin-row-${name}`)).toBeVisible();
    } finally {
      await disablePlugin(page, name);
    }
  });

  test('a required option left empty is named on its field and nothing is enabled', async ({
    page,
  }) => {
    const name = uniqueId('pw_unsent');

    try {
      await fillEnable(page, name, 'hook_webhook', ['on_relay_started'], {});

      await expect(optionError(page, 'url')).toContainText('is required');
      await expect(page.getByTestId('attach-modal')).toBeVisible();
      await page.getByTestId('attach-cancel-btn').click();

      await expect(page.getByTestId(`plugin-row-${name}`)).toHaveCount(0);
    } finally {
      await disablePlugin(page, name);
    }
  });
});
