import { test, expect, testIds, type Page } from './fixtures';

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

/** The factory ids the start modal offers, without its placeholder option. */
async function factoryOptions(page: Page): Promise<string[]> {
  const select = page.getByTestId('input-factory-id');
  await expect(select).toBeEnabled();

  return select
    .locator('option')
    .evaluateAll((opts) =>
      opts.map((o) => (o as HTMLOptionElement).value).filter((v) => v !== ''),
    );
}

/** Selects the first real factory option and returns its id. */
/**
 * A factory that can actually be started as a `:stream` operative.
 *
 * The runner registers its whole catalogue, most of which are workflow
 * factories — and the first one alphabetically (`bench_chain_1`) is one of
 * them. Taking whichever sorts first asks the controller to run a workflow as
 * a stream, which it refuses. `store_input` is the stream factory the dev
 * stack documents and seeds against.
 */
async function selectFirstFactory(page: Page): Promise<string> {
  const options = await factoryOptions(page);

  expect(options.length, 'at least one factory must be available').toBeGreaterThan(0);

  const factoryId = options.includes('store_input') ? 'store_input' : options[0];
  await page.getByTestId('input-factory-id').selectOption(factoryId);
  return factoryId;
}

async function startOperative(page: Page, id: string) {
  await page.getByTestId('start-operative-btn').click();
  await expect(page.getByTestId('start-modal')).toBeVisible();
  await page.getByTestId('input-operative-id').fill(id);
  await selectFirstFactory(page);
  await page.getByTestId('start-submit-btn').click();

  await expect(page.getByTestId('start-modal')).toHaveCount(0);
  await expect(page.getByTestId(`operative-row-${id}`)).toBeVisible();
}

/**
 * Cleanup, so a failure does not leak a running operative.
 *
 * Tolerating an already-stopped operative is what makes this safe to call from
 * `finally` after the test stopped it itself; it never skips an assertion.
 */
async function stopOperative(page: Page, id: string) {
  const row = page.getByTestId(`operative-row-${id}`);
  if ((await row.count()) === 0) return;

  await page.getByTestId(`stop-operative-${id}`).click();
  await expect(page.getByTestId('stop-confirm-modal')).toBeVisible();
  await page.getByTestId('stop-confirm-btn').click();
  await expect(row).toHaveCount(0);
}

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
    await selectFirstFactory(page);
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

  test('starts an operative with init values JSON', async ({ page }) => {
    const id = uniqueOperativeId('pw_json');

    try {
      await page.getByTestId('start-operative-btn').click();
      await expect(page.getByTestId('start-modal')).toBeVisible();

      await page.getByTestId('input-operative-id').fill(id);
      await selectFirstFactory(page);
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
