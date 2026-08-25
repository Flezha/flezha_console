import {
  test,
  expect,
  testIds,
  factoryOptions,
  startOperative,
  stopOperative,
  type Page,
} from './fixtures';

/**
 * Starting and stopping operatives, from the namespace show page.
 *
 * Every test cleans up what it started, and asserts the operative count
 * returns to where it began — that assertion is what catches a leaked
 * operative, and it is why the suite runs single-worker.
 */

const NAMESPACE = 'default';
const NAMESPACE_URL = `/namespaces/${NAMESPACE}`;

/** Unique per test, so a leftover from a failed run cannot collide. */
function uniqueOperativeId(prefix = 'pw_test'): string {
  const ts = Date.now().toString(36).slice(-4);
  const rand = Math.random().toString(36).slice(2, 5);
  return `${prefix}_${ts}_${rand}`;
}

/** The operative ids currently shown in the table. */
const operativeIds = (page: Page) => testIds(page, 'operative-row-');

test.describe('Operative lifecycle', () => {
  test.beforeEach(async ({ live }) => {
    await live(NAMESPACE_URL);
  });

  test('opens the start modal and lists available factories', async ({ page }) => {
    await page.getByTestId('start-operative-btn').click();
    await expect(page.getByTestId('start-modal')).toBeVisible();

    const factories = await factoryOptions(page);
    expect(factories.length, 'at least one factory should be available').toBeGreaterThan(0);

    await page.getByTestId('start-cancel-btn').click();
    await expect(page.getByTestId('start-modal')).toHaveCount(0);
  });

  test('validates required fields', async ({ page }) => {
    await page.getByTestId('start-operative-btn').click();
    await expect(page.getByTestId('start-modal')).toBeVisible();

    await page.getByTestId('start-submit-btn').click();

    // The modal stays open and says what is missing.
    await expect(page.getByTestId('start-modal')).toBeVisible();
    await expect(page.getByTestId('start-error')).toContainText('required');

    await page.getByTestId('start-cancel-btn').click();
    await expect(page.getByTestId('start-modal')).toHaveCount(0);
  });

  test('validates invalid JSON in init values', async ({ page }) => {
    await page.getByTestId('start-operative-btn').click();
    await expect(page.getByTestId('start-modal')).toBeVisible();

    await page.getByTestId('input-operative-id').fill(uniqueOperativeId());
    await page.getByTestId('input-factory-id').selectOption((await factoryOptions(page))[0]);
    await page.getByTestId('input-init-values').fill('not valid json{{{');

    await page.getByTestId('start-submit-btn').click();

    await expect(page.getByTestId('start-modal')).toBeVisible();
    await expect(page.getByTestId('start-error')).toContainText('JSON');

    await page.getByTestId('start-cancel-btn').click();
  });

  test('starts an operative and it appears in the table', async ({ page }) => {
    const id = uniqueOperativeId();
    const before = await operativeIds(page);

    try {
      await startOperative(page, id);

      await expect(page.locator('body')).toContainText(`Operative ${id} started`);

      const after = await operativeIds(page);
      expect(after).toContain(id);
      expect(after.length).toBe(before.length + 1);
    } finally {
      await stopOperative(page, id);
    }

    expect(await operativeIds(page)).toEqual(before);
  });

  test('starts an operative, navigates to its detail page, then stops it', async ({
    page,
    live,
  }) => {
    const id = uniqueOperativeId('pw_nav');

    try {
      await startOperative(page, id);

      await page.getByTestId(`view-operative-${id}`).click();
      await expect(page).toHaveURL(new RegExp(`/namespaces/${NAMESPACE}/operatives/${id}$`));
      await expect(page.locator('body')).toContainText(id);

      await live(NAMESPACE_URL);

      // The operative survives navigating away and back.
      await expect(page.getByTestId(`operative-row-${id}`)).toBeVisible();

      await stopOperative(page, id);
      await expect(page.locator('body')).toContainText(`Operative ${id} stopped`);
      await expect(page.locator('body')).not.toContainText('Failed');
    } finally {
      await stopOperative(page, id);
    }
  });

  test('cancelling the stop confirmation leaves the operative running', async ({ page }) => {
    const id = uniqueOperativeId('pw_cancel');

    try {
      await startOperative(page, id);

      await page.getByTestId(`stop-operative-${id}`).click();
      await expect(page.getByTestId('stop-confirm-modal')).toBeVisible();
      await page.getByTestId('stop-cancel-btn').click();
      await expect(page.getByTestId('stop-confirm-modal')).toHaveCount(0);

      await expect(page.getByTestId(`operative-row-${id}`)).toBeVisible();
    } finally {
      await stopOperative(page, id);
    }
  });

  test('starts multiple operatives and stops them all', async ({ page }) => {
    const ids = [uniqueOperativeId('pw_multi_a'), uniqueOperativeId('pw_multi_b')];
    const before = await operativeIds(page);

    try {
      for (const id of ids) {
        await startOperative(page, id);
      }

      const after = await operativeIds(page);
      for (const id of ids) {
        expect(after, `${id} should be in the table`).toContain(id);
      }
    } finally {
      for (const id of ids) {
        await stopOperative(page, id);
      }
    }

    expect(await operativeIds(page)).toEqual(before);
  });

  test('offers the kinds the controller recognises, with their capabilities', async ({
    page,
  }) => {
    await page.getByTestId('start-operative-btn').click();
    await expect(page.getByTestId('start-modal')).toBeVisible();

    const kinds = await page
      .getByTestId('input-kind')
      .locator('option')
      .evaluateAll((opts) => opts.map((o) => (o as HTMLOptionElement).value));

    expect(kinds).toContain('stream');
    expect(kinds).toContain('workflow');

    // The capability the choice actually costs: a workflow keeps no entity
    // state, and the form says so before the operator commits.
    await expect(page.getByTestId('start-modal')).toContainText('persistent_state?');
    await page.getByTestId('input-kind').selectOption('workflow');
    await expect(page.getByTestId('start-modal')).toContainText('no persistent entity state');

    await page.getByTestId('start-cancel-btn').click();
  });

  test('the factory selector names each factory and who serves it', async ({ page }) => {
    await page.getByTestId('start-operative-btn').click();
    await expect(page.getByTestId('start-modal')).toBeVisible();

    await page.getByTestId('input-factory-id').selectOption('store_input');

    // A connected runner serves the seeded factory, so the form says which.
    await expect(page.getByTestId('start-modal')).toContainText('Served by');

    await page.getByTestId('start-cancel-btn').click();
  });

  test('starts a workflow, which the form could not do before', async ({ live, page }) => {
    const id = uniqueOperativeId('pw_wf');

    try {
      await startOperative(page, id, { kind: 'workflow' });

      await expect(page.getByTestId(`operative-row-${id}`)).toBeVisible();

      // The index is where kind is reported, and it must read back as a
      // workflow rather than the `:stream` every start used to default to.
      await live('/operatives');
      await expect(page.getByTestId(`operative-index-row-${id}`)).toContainText('workflow');
    } finally {
      await live(NAMESPACE_URL);
      await stopOperative(page, id);
    }
  });

  test('starts an operative with init values JSON', async ({ page }) => {
    const id = uniqueOperativeId('pw_json');

    try {
      await page.getByTestId('start-operative-btn').click();
      await expect(page.getByTestId('start-modal')).toBeVisible();

      await page.getByTestId('input-operative-id').fill(id);
      await page.getByTestId('input-factory-id').selectOption('store_input');
      await page.getByTestId('input-init-values').fill('{}');

      await page.getByTestId('start-submit-btn').click();

      // `{}` is valid init values, so this must succeed rather than be
      // tolerated either way.
      await expect(page.getByTestId('start-modal')).toHaveCount(0);
      await expect(page.getByTestId(`operative-row-${id}`)).toBeVisible();
    } finally {
      await stopOperative(page, id);
    }
  });
});
