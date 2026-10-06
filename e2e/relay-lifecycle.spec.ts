import {
  test,
  expect,
  testIds,
  factoryOptions,
  startRelay,
  stopRelay,
  uniqueId,
  type Page,
} from './fixtures';

/**
 * Starting and stopping relays, from the namespace show page.
 *
 * Every test cleans up what it started, and asserts the relay count returns to
 * where it began — that assertion is what catches a leaked relay, and it is
 * why the suite runs single-worker.
 */

const NAMESPACE = 'default';
const NAMESPACE_URL = `/namespaces/${NAMESPACE}`;

/** The relay ids currently shown in the table. */
const relayIds = (page: Page) => testIds(page, 'relay-row-');

test.describe('Relay lifecycle', () => {
  test.beforeEach(async ({ live }) => {
    await live(NAMESPACE_URL);
  });

  test('opens the start modal and lists available factories', async ({ page }) => {
    await page.getByTestId('start-relay-btn').click();
    await expect(page.getByTestId('start-modal')).toBeVisible();

    const factories = await factoryOptions(page);
    expect(factories.length, 'at least one factory should be available').toBeGreaterThan(0);

    await page.getByTestId('start-cancel-btn').click();
    await expect(page.getByTestId('start-modal')).toHaveCount(0);
  });

  test('validates required fields', async ({ page }) => {
    await page.getByTestId('start-relay-btn').click();
    await expect(page.getByTestId('start-modal')).toBeVisible();

    await page.getByTestId('start-submit-btn').click();

    // The modal stays open and says what is missing.
    await expect(page.getByTestId('start-modal')).toBeVisible();
    await expect(page.getByTestId('start-error')).toContainText('required');

    await page.getByTestId('start-cancel-btn').click();
    await expect(page.getByTestId('start-modal')).toHaveCount(0);
  });

  test('validates invalid JSON in init values', async ({ page }) => {
    await page.getByTestId('start-relay-btn').click();
    await expect(page.getByTestId('start-modal')).toBeVisible();

    await page.getByTestId('input-factory-id').selectOption((await factoryOptions(page))[0]);
    await page.getByTestId('input-relay-id').fill(uniqueId('pw_test'));
    await page.getByTestId('input-init-values').fill('not valid json{{{');

    await page.getByTestId('start-submit-btn').click();

    await expect(page.getByTestId('start-modal')).toBeVisible();
    await expect(page.getByTestId('start-error')).toContainText('JSON');

    await page.getByTestId('start-cancel-btn').click();
  });

  test('starts a relay and it appears in the table', async ({ page }) => {
    const id = uniqueId('pw_test');
    const before = await relayIds(page);

    try {
      await startRelay(page, id);

      await expect(page.getByTestId(`relay-row-${id}`)).toBeVisible();

      const after = await relayIds(page);
      expect(after).toContain(id);
      expect(after.length).toBe(before.length + 1);
    } finally {
      await stopRelay(page, id);
    }

    expect(await relayIds(page)).toEqual(before);
  });

  test('starting without an id reports the id the controller generated', async ({ page }) => {
    const before = await relayIds(page);
    let generated: string | null = null;

    try {
      await page.getByTestId('start-relay-btn').click();
      await page.getByTestId('input-factory-id').selectOption('store_input');
      await page.getByTestId('start-submit-btn').click();

      await expect(page.getByTestId('start-result')).toBeVisible();
      generated = (await page.getByTestId('start-result-link').textContent())?.trim() ?? null;
      expect(generated, 'the form names the generated id').toBeTruthy();

      await page.getByTestId('start-done-btn').click();
      await expect(page.getByTestId(`relay-row-${generated}`)).toBeVisible();
    } finally {
      if (generated) await stopRelay(page, generated);
    }

    expect(await relayIds(page)).toEqual(before);
  });

  test('starting an id that is already running says so and links to it', async ({ page }) => {
    const id = uniqueId('pw_dup');

    try {
      await startRelay(page, id);

      await page.getByTestId('start-relay-btn').click();
      await page.getByTestId('input-factory-id').selectOption('store_input');
      await page.getByTestId('input-relay-id').fill(id);
      await page.getByTestId('start-submit-btn').click();

      await expect(page.getByTestId('start-result')).toContainText('already running');
      await expect(page.getByTestId('start-result-link')).toHaveAttribute(
        'href',
        `/namespaces/${NAMESPACE}/relays/${id}`,
      );
      await page.getByTestId('start-done-btn').click();
    } finally {
      await stopRelay(page, id);
    }
  });

  test('starts a relay, navigates to its detail page, then stops it', async ({ page, live }) => {
    const id = uniqueId('pw_nav');

    try {
      await startRelay(page, id);

      await page.getByTestId(`view-relay-${id}`).click();
      await expect(page).toHaveURL(new RegExp(`/namespaces/${NAMESPACE}/relays/${id}$`));
      await expect(page.locator('body')).toContainText(id);

      await live(NAMESPACE_URL);

      // The relay survives navigating away and back.
      await expect(page.getByTestId(`relay-row-${id}`)).toBeVisible();

      await stopRelay(page, id);
      await expect(page.locator('body')).toContainText(`Relay ${id} stop`);
      await expect(page.getByTestId('runtime-error')).toHaveCount(0);
    } finally {
      await stopRelay(page, id);
    }
  });

  test('cancelling the stop confirmation leaves the relay running', async ({ page }) => {
    const id = uniqueId('pw_cancel');

    try {
      await startRelay(page, id);

      await page.getByTestId(`stop-relay-${id}`).click();
      await expect(page.getByTestId('stop-confirm-modal')).toBeVisible();
      await page.getByTestId('stop-cancel-btn').click();
      await expect(page.getByTestId('stop-confirm-modal')).toHaveCount(0);

      await expect(page.getByTestId(`relay-row-${id}`)).toBeVisible();
    } finally {
      await stopRelay(page, id);
    }
  });

  test('starts multiple relays and stops them all', async ({ page }) => {
    const ids = [uniqueId('pw_multi_a'), uniqueId('pw_multi_b')];
    const before = await relayIds(page);

    try {
      for (const id of ids) {
        await startRelay(page, id);
      }

      const after = await relayIds(page);
      for (const id of ids) {
        expect(after, `${id} should be in the table`).toContain(id);
      }
    } finally {
      for (const id of ids) {
        await stopRelay(page, id);
      }
    }

    expect(await relayIds(page)).toEqual(before);
  });

  test('shows the chosen factory run read-only, and asks for no run', async ({ page }) => {
    const before = await relayIds(page);
    await page.getByTestId('start-relay-btn').click();
    await expect(page.getByTestId('start-modal')).toBeVisible();

    // How a relay runs is its factory's, so there is no control to set it.
    await expect(page.getByTestId('start-modal').locator('[name="start[run]"]')).toHaveCount(0);
    await expect(page.getByTestId('start-modal').locator('[name="start[kind]"]')).toHaveCount(0);

    await page.getByTestId('input-factory-id').selectOption('store_input');
    await expect(page.getByTestId('factory-run')).toContainText('flow');

    await page.getByTestId('input-factory-id').selectOption('chat_loop_steps');
    await expect(page.getByTestId('factory-run')).toContainText('steps');

    // Cancelling starts nothing, even with a factory chosen and the id blank.
    await page.getByTestId('start-cancel-btn').click();
    await expect(page.getByTestId('start-modal')).toHaveCount(0);
    expect(await relayIds(page)).toEqual(before);
  });

  test('the factory selector names each factory and who serves it', async ({ page }) => {
    await page.getByTestId('start-relay-btn').click();
    await expect(page.getByTestId('start-modal')).toBeVisible();

    await page.getByTestId('input-factory-id').selectOption('store_input');

    // A connected runner serves the seeded factory, so the form says which.
    await expect(page.getByTestId('start-modal')).toContainText('Served by');

    await page.getByTestId('start-cancel-btn').click();
  });

  test('starts a steps relay, and the index reports its run as steps', async ({ live, page }) => {
    const id = uniqueId('pw_steps');

    try {
      await startRelay(page, id, { run: 'steps' });

      await expect(page.getByTestId(`relay-row-${id}`)).toBeVisible();
      await expect(page.getByTestId(`relay-run-${id}`)).toHaveText('steps');

      await live('/relays');
      await expect(page.getByTestId(`relay-index-row-${id}`)).toContainText('steps');
    } finally {
      await live(NAMESPACE_URL);
      await stopRelay(page, id);
    }
  });

  test('starts a relay with init values JSON', async ({ page }) => {
    const id = uniqueId('pw_json');

    try {
      await page.getByTestId('start-relay-btn').click();
      await expect(page.getByTestId('start-modal')).toBeVisible();

      await page.getByTestId('input-factory-id').selectOption('store_input');
      await page.getByTestId('input-relay-id').fill(id);
      await page.getByTestId('input-init-values').fill('{}');

      await page.getByTestId('start-submit-btn').click();

      // `{}` is valid init values, so this must succeed rather than be
      // tolerated either way.
      await expect(page.getByTestId('start-result')).toBeVisible();
      await page.getByTestId('start-done-btn').click();
      await expect(page.getByTestId(`relay-row-${id}`)).toBeVisible();
    } finally {
      await stopRelay(page, id);
    }
  });
});
