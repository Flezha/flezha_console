import {
  openSection,
  menuAction,
  ownRelay,
  test,
  expect,
  disablePlugin,
  fillPluginForm,
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
 * which the loader refuses. Every relay plugin is bound to relays this file
 * starts, and every plugin a test enables it disables in `finally`. The
 * option checks, the cancelled confirmations and the transient option's
 * password field are asserted in `test/flezha_console_web/live/plugin_live_test.exs`.
 */
const PLUGINS_URL = '/namespaces/default/plugins';

/** Enables `name` from the plugins screen and asserts the dialog closed on success. */
async function enable(
  page: Page,
  name: string,
  provider: string,
  hooks: string[],
  opts: Record<string, string>,
  relay?: string,
) {
  await fillPluginForm(page, 'enable-plugin-btn', { provider, name, relay, hooks, opts });
  await page.getByTestId('attach-submit-btn').click();
  await expect(page.getByTestId('attach-modal')).toHaveCount(0);
}

/** The hint shown on an option's field. */
const optionHint = (page: Page, option: string) =>
  page.getByTestId(`input-option-${option}`).locator('xpath=..').locator('.fcon-hint');

const RECEIVER = 'http://fcon_web:4000/dev/null';

const { id: RELAY } = ownRelay('pw_pm');
const { id: FURTHER } = ownRelay('pw_pm2');


test.describe('Plugin packages', () => {
  test.beforeEach(async ({ live }) => {
    await live(PLUGINS_URL);
  });

  test('the loaded package lists its providers; the refused one explains itself and is counted', async ({
    page,
  }) => {
    await expect(page.getByTestId('installed-status-flezha_http')).toHaveText(/Loaded/);
    await expect(page.getByTestId('installed-providers-flezha_http')).toContainText('http_server');

    await expect(page.getByTestId('installed-status-flezha_http_tampered')).toHaveText(/Refused/);

    const error = page.getByTestId('installed-error-flezha_http_tampered');
    await expect(error).toContainText(/plugin\.[a-z_]+/);
    await expect(error.getByTestId('runtime-error-reference')).toHaveAttribute(
      'href',
      /\/errors\.html#plugin$/,
    );

    await openSection(page, 'providers');
    await expect(page.getByTestId('providers-refused')).toContainText('refused 1 installed package');
  });
});

test.describe('Plugin writes', () => {
  test.beforeEach(async ({ live }) => {
    await live(PLUGINS_URL);
  });

  test('a controller plugin is enabled with controller hooks and no relay, and updated', async ({ page }) => {
    const name = uniqueId('pw_hooks');

    try {
      await page.getByTestId('enable-plugin-btn').click();
      await page.getByTestId('provider-btn-hook_webhook').click();

      // What it is and what it will ask for are said before the form.
      const detail = page.getByTestId('provider-detail');
      await expect(detail).toContainText('Controller plugins');
      await expect(detail).toContainText('on_relay_started');
      await expect(detail).toContainText('url');
      await page.getByTestId('provider-use-btn').click();

      // A controller plugin runs on controllers, so no relay is asked for.
      await expect(page.getByTestId('input-plugin-relay')).toHaveCount(0);
      await expect(page.getByTestId('input-plugin-single')).toBeVisible();

      await page.getByTestId('input-plugin-name').fill(name);
      await page.getByTestId('input-hook-on_relay_started').check();
      await page.getByTestId('attach-next-btn').click();

      // The required option is checked before the review opens.
      await page.getByTestId('attach-next-btn').click();
      await expect(page.getByTestId('input-option-url').locator('xpath=..').locator('.fcon-error')).toContainText(
        'is required',
      );
      await page.getByTestId('input-option-url').fill(RECEIVER);
      await page.getByTestId('attach-next-btn').click();

      await expect(page.getByTestId('plugin-review')).toContainText('Enable Hook Webhook');
      await expect(page.getByTestId('plugin-command')).toHaveText(
        `flz plugin enable ${name} hook_webhook --namespace default --hook=on_relay_started --Xurl=${RECEIVER}`,
      );
      await page.getByTestId('attach-submit-btn').click();

      // One controller holds the namespace, so none lacks the provider.
      await expect(page.locator('body')).toContainText(`Plugin ${name} enabled.`);
      await expect(page.locator('body')).not.toContainText('does not run on');

      const row = page.getByTestId(`plugin-row-${name}`);
      await expect(row).toContainText('on_relay_started');
      await expect(page.getByTestId(`plugin-controllers-${name}`)).toContainText('flezha@');
      await expect(page.getByTestId(`plugin-bind-${name}`)).toHaveCount(0);

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

  test('a relay plugin is bound to a further relay, unbound and updated', async ({ page }) => {
    const name = uniqueId('pw_out');

    try {
      await enable(page, name, 'relay_stdout', ['on_output'], {}, RELAY);
      await expect(page.getByTestId(`plugin-relays-${name}`)).toContainText(RELAY);

      // Bind
      await menuAction(page, `plugin-menu-${name}`, `plugin-bind-${name}`);
      await page.getByTestId('input-plugin-relay').selectOption(FURTHER);
      await page.getByTestId('input-hook-on_output').check();
      await page.getByTestId('attach-submit-btn').click();
      await expect(page.locator('body')).toContainText(`Plugin ${name} bound to ${FURTHER}.`);
      await expect(page.getByTestId(`plugin-relays-${name}`)).toContainText(FURTHER);

      // Unbind, after a confirmation
      await menuAction(page, `plugin-menu-${name}`, `plugin-unbind-${name}-${FURTHER}`);
      await expect(page.getByTestId('plugin-unbind-modal')).toContainText('stays enabled');
      await page.getByTestId('plugin-unbind-confirm').click();
      await expect(page.getByTestId(`plugin-relays-${name}`)).not.toContainText(FURTHER);
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

  test('relay_http_push takes typed options, and relay_io_filter a true/false one', async ({ page }) => {
    const push = uniqueId('pw_push');
    const filter = uniqueId('pw_filter');

    try {
      await enable(
        page,
        push,
        'relay_http_push',
        ['on_output'],
        {
          url: RECEIVER,
          method: 'PUT',
          headers: '{"x-test": "1"}',
          channel: 'a, b',
          timeout_ms: '2000',
        },
        RELAY,
      );
      await expect(page.locator('body')).toContainText(`Plugin ${push} enabled and bound to ${RELAY}.`);
      await expect(page.getByTestId(`plugin-row-${push}`)).toBeVisible();

      await enable(
        page,
        filter,
        'relay_io_filter',
        ['on_output'],
        { regex_pattern: '^pw-never-matches$', inverted: 'true' },
        RELAY,
      );
      await expect(page.getByTestId(`plugin-row-${filter}`)).toBeVisible();
    } finally {
      try {
        await disablePlugin(page, push);
      } finally {
        await disablePlugin(page, filter);
      }
    }
  });
});
