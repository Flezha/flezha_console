import {
  test,
  expect,
  factoryOptions,
  startRelayCli,
  stopRelay,
  stopRelayCli,
  SEEDED_FACTORY,
  uniqueId,
  openSection,
  expectAdvances,
  menuAction,
  openStart,
  chooseFactory,
  reviewAndStart,
  sendRecords,
} from './fixtures';

/**
 * Starting, viewing and stopping relays, from a namespace's relays screen.
 *
 * Each test starts its own relays and asserts on them by id; every relay it
 * started is stopped and no longer listed when it finishes. What the start
 * form refuses before the controller is asserted in `launcher_test.exs`.
 */

const NAMESPACE = 'default';
const NAMESPACE_URL = `/namespaces/${NAMESPACE}/relays`;

test.describe('Relay lifecycle', () => {
  test.beforeEach(async ({ live }) => {
    await live(NAMESPACE_URL);
  });

  test('starts a relay under a generated id, refuses that id again, views it, and stops it', async ({
    page,
  }) => {
    let id: string | null = null;

    try {
      await openStart(page);
      expect((await factoryOptions(page)).length, 'at least one factory is served').toBeGreaterThan(0);
      await chooseFactory(page, 'store_input');
      await page.getByTestId('start-back-btn').click();
      await chooseFactory(page, 'store_input');
      // No id, so the controller draws one; `{}` is valid init values.
      await page.getByTestId('input-init-values').fill('{}');
      await reviewAndStart(page);

      await expect(page.getByTestId('start-result')).toBeVisible();
      id = (await page.getByTestId('start-result-link').textContent())?.trim() || null;
      expect(id, 'the form names the generated id').toBeTruthy();
      await page.getByTestId('start-done-btn').click();
      await expect(page.getByTestId(`relay-index-row-${id}`)).toBeVisible();

      await openStart(page);
      await chooseFactory(page, 'store_input');
      await page.getByTestId('input-relay-id').fill(id!);
      await reviewAndStart(page);
      await expect(page.getByTestId('start-result')).toContainText('already running');
      await expect(page.getByTestId('start-result-link')).toHaveAttribute(
        'href',
        `/namespaces/${NAMESPACE}/relays/${id}`,
      );
      await page.getByTestId('start-done-btn').click();

      await menuAction(page, `relay-menu-${id}`, `view-relay-${id}`);
      await expect(page).toHaveURL(new RegExp(`/namespaces/${NAMESPACE}/relays/${id}$`));
      await expect(page.getByTestId('relay-run')).toHaveText('A flow relay');
      await expect(page.getByTestId('relay-runner')).toHaveText(/\S/);
      await expect(page.getByTestId('relay-node')).toContainText('flezha@');
      await expect(page.getByTestId('relay-health')).toContainText('It is healthy');
      await expect(page.getByTestId('relay-uptime')).toHaveText(
        /^, up for ((\d+h )?\d+m( \d+s)?|\d+(ms|s))$/,
      );

      await stopRelay(page, id!);
      await expect(page.locator('body')).toContainText(`Relay ${id} stop`);
      await expect(page.getByTestId('runtime-error')).toHaveCount(0);
    } finally {
      if (id) await stopRelay(page, id);
    }
  });

  test('reads the SDK state, keeps it current, narrows it by tasklet, and refuses an unknown one', async ({
    page,
    live,
  }) => {
    const id = uniqueId('pw_state');

    try {
      startRelayCli(id, SEEDED_FACTORY.flow);
      await live(`${NAMESPACE_URL}/${id}/state`);
      await openSection(page, 'sdk-state');

      const toggle = page.getByTestId('state-auto-refresh');
      await page.getByTestId('state-auto-refresh').click();
      await expect(toggle).toHaveAttribute('aria-pressed', 'true');

      // The relay's tasklet keeps every input it is sent.
      sendRecords(id, [uniqueId('pw_in')]);
      await expect(page.getByTestId('state-json')).toContainText('store_input_tasklet');
      await expectAdvances(page.getByTestId('state-seq'), 'the auto-refreshed state sequence', () =>
        sendRecords(id, [uniqueId('pw_in')]),
      );

      await page.getByTestId('state-auto-refresh').click();
      await expect(toggle).toHaveAttribute('aria-pressed', 'false');

      await page.getByTestId('input-selector-tasklet').fill('store_input_tasklet');
      await page.getByTestId('input-selector-cell-key').fill('');
      await page.getByTestId('fetch-state-btn').click();
      await expect(page.getByTestId('state-json')).toContainText('text_inputs');

      await page.getByTestId('input-selector-tasklet').fill('no_such_tasklet');
      await page.getByTestId('fetch-state-btn').click();
      await expect(page.getByTestId('runtime-error')).toContainText('state.tasklet_not_found');
      await expect(page.getByTestId('state-json')).toHaveCount(0);
    } finally {
      stopRelayCli(id);
    }
  });
});
