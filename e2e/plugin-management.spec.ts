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

/**
 * Fills the plugin form from the plugins screen: `provider`, `hooks` and each
 * option typed into its own field, a selection chosen by its value. Submits
 * without asserting the outcome.
 */
async function fillEnable(
  page: Page,
  name: string,
  provider: string,
  hooks: string[],
  opts: Record<string, string>,
  relay?: string,
) {
  await page.getByTestId('enable-plugin-btn').click();
  await page.getByTestId(`provider-btn-${provider}`).click();
  await page.getByTestId('input-plugin-name').fill(name);
  if (relay) await page.getByTestId('input-plugin-relay').selectOption(relay);
  for (const hook of hooks) await page.getByTestId(`input-hook-${hook}`).check();

  for (const [option, value] of Object.entries(opts)) {
    const field = page.getByTestId(`input-option-${option}`);
    if ((await field.evaluate((el) => el.tagName)) === 'SELECT') await field.selectOption(value);
    else await field.fill(value);
  }

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

/** The error shown on an option's field, inside the field's own container. */
const optionError = (page: Page, option: string) =>
  page.getByTestId(`input-option-${option}`).locator('xpath=..').locator('.flz-field-error');

/** The hint shown on an option's field. */
const optionHint = (page: Page, option: string) =>
  page.getByTestId(`input-option-${option}`).locator('xpath=..').locator('.flz-field-hint');

const RECEIVER = 'http://fui_web:4000/dev/null';

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

      // Update, with nothing filled in
      await page.getByTestId(`plugin-update-${name}`).click();
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

      await page.getByTestId(`plugin-update-${name}`).click();
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
