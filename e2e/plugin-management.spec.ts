import { test, expect, disablePlugin, uniqueId, type Page } from './fixtures';

/**
 * The plugin packages the controller holds and the plugin writes made from the
 * plugins screen: a controller plugin enabled with controller hooks, and a
 * relay plugin bound to a further relay, unbound and given new options.
 *
 * The dev stack places two packages before the controller boots
 * (`priv/dev/plugin_packages.sh`): `flezha_http`, which loads, and
 * `flezha_http_tampered`, whose manifest changed after it was checksummed,
 * which the loader refuses. Every plugin a test enables it disables in
 * `finally`.
 */
const PLUGINS_URL = '/namespaces/default/plugins';

/** Enables `name` from the plugins screen with `provider`, `hooks` and `opts`. */
async function enable(
  page: Page,
  name: string,
  provider: string,
  hooks: string[],
  opts: Record<string, unknown>,
  relay?: string,
) {
  await page.getByTestId('enable-plugin-btn').click();
  await page.getByTestId(`provider-btn-${provider}`).click();
  await page.getByTestId('input-plugin-name').fill(name);
  if (relay) await page.getByTestId('input-plugin-relay').selectOption(relay);
  for (const hook of hooks) await page.getByTestId(`input-hook-${hook}`).check();
  await page.getByTestId('input-plugin-opts').fill(JSON.stringify(opts));
  await page.getByTestId('attach-submit-btn').click();
  await expect(page.getByTestId('attach-modal')).toHaveCount(0);
}

test.describe('Plugin packages', () => {
  test.beforeEach(async ({ live }) => {
    await live(PLUGINS_URL);
  });

  test('the loaded package lists its providers', async ({ page }) => {
    await expect(page.getByTestId('installed-status-flezha_http')).toHaveText(/loaded/);
    await expect(page.getByTestId('installed-providers-flezha_http')).toContainText('http_server');
  });

  test('the refused package explains itself and its count is stated', async ({ page }) => {
    await expect(page.getByTestId('installed-status-flezha_http_tampered')).toHaveText(/refused/);

    const error = page.getByTestId('installed-error-flezha_http_tampered');
    await expect(error).toContainText(/\(plugin\.[a-z_]+\)/);
    await expect(error.getByTestId('runtime-error-reference')).toHaveAttribute(
      'href',
      /\/errors\.html#plugin$/,
    );

    await expect(page.getByTestId('providers-refused')).toContainText('refused 1 installed package');
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
      await page.getByTestId('input-plugin-opts').fill('{"url": "http://fui_web:4000/dev/null"}');
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
      await page.getByTestId(`plugin-bind-${name}`).click();
      await page.getByTestId('input-plugin-relay').selectOption('testnet_store_2');
      await page.getByTestId('input-hook-on_output').check();
      await page.getByTestId('attach-submit-btn').click();
      await expect(page.locator('body')).toContainText(`Plugin ${name} bound to testnet_store_2.`);
      await expect(page.getByTestId(`plugin-relays-${name}`)).toContainText('testnet_store_2');

      // Unbind, after a confirmation
      await page.getByTestId(`plugin-unbind-${name}-testnet_store_2`).click();
      await expect(page.getByTestId('plugin-unbind-modal')).toContainText('stays enabled');
      await page.getByTestId('plugin-unbind-confirm').click();
      await expect(page.getByTestId(`plugin-relays-${name}`)).not.toContainText('testnet_store_2');
      await expect(page.getByTestId(`plugin-row-${name}`)).toBeVisible();

      // Update
      await page.getByTestId(`plugin-update-${name}`).click();
      await page.getByTestId('input-plugin-opts').fill('{}');
      await page.getByTestId('attach-submit-btn').click();
      await expect(page.locator('body')).toContainText(
        new RegExp(`Plugin ${name} updated: (applied live|applied by restarting its copies|nothing changed)\\.`),
      );
    } finally {
      await disablePlugin(page, name);
    }
  });
});
