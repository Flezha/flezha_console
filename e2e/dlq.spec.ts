import {
  test,
  expect,
  sendRecords,
  startRelayCli,
  stopRelayCli,
  uniqueId,
  visitLive,
  menuAction,
  workerPage,
  type Page,
} from './fixtures';

/**
 * The dead-letter queue screen, against entries this file parks itself.
 *
 * The dev runner's `poison_probe` factory fails on the input `poison` until it
 * is sent `antidote`; after its retries the controller parks the input. The
 * antidote is never sent, because it is process-wide on the runner and would
 * change every later run. One relay under a run-unique id holds the file's
 * entry: without the effectively-once tier the controller keys an entry on its
 * channel and payload, so a relay can park `poison` once. Each test filters
 * the queue to that relay class, listing seen entries too; the entry is marked
 * seen, then replayed, which parks it unseen as its next generation, before
 * it is dropped, and whatever is left is dropped before the relay is stopped.
 */
const TASKLET = 'poison_probe_tasklet';

let relay: string;
let ref: string;
let admin: Page;

function statTerm(page: Page) {
  return page.getByTestId('dlq-stats').getByText(`${relay}/${TASKLET}`, { exact: true });
}

const group = (page: Page) => page.getByTestId(`dlq-group-${relay}-${TASKLET}`);
const groupCount = (page: Page) => page.getByTestId(`dlq-group-count-${relay}-${TASKLET}`);

/** The ref of each entry the relay's group lists. */
async function listedRefs(page: Page): Promise<string[]> {
  return group(page)
    .locator('[data-testid^="dlq-row-"]')
    .evaluateAll((rows) =>
      rows.map((row) => (row.getAttribute('data-testid') ?? '').slice('dlq-row-'.length)),
    );
}

/** The queue filtered to the relay, seen entries listed too unless `seen` is false. */
async function openQueue(page: Page, { seen = true } = {}): Promise<void> {
  await visitLive(page, seen ? '/dlq?seen=shown' : '/dlq');
  await page.getByTestId('dlq-filter').fill(relay);
}

test.beforeAll(async ({ browser }, testInfo) => {
  admin = await workerPage(browser, testInfo);
  relay = uniqueId('pw_dlq');

  await startRelayCli(relay, 'poison_probe');
  await sendRecords(relay, ['poison']);

  await openQueue(admin);
  await expect(groupCount(admin)).toHaveText('1 dead letter');
  [ref] = await listedRefs(admin);
});

test.afterAll(async () => {
  // Only this relay's group is ever touched: the queue is shared.
  await openQueue(admin);
  for (const left of await listedRefs(admin)) {
    await menuAction(admin, `dlq-menu-${left}`, `dlq-drop-${left}`);
    await admin.getByTestId('dlq-confirm-submit').click();
    await expect(admin.getByTestId(`dlq-row-${left}`)).toHaveCount(0);
  }
  await stopRelayCli(relay);
  await admin.context().close();
});

test.describe('Dead-letter queue', () => {
  test.beforeEach(async ({ page }) => {
    await openQueue(page);
  });

  test('a poisoned input becomes a dead letter under its relay and tasklet, counted, filtered and inspected', async ({
    page,
  }) => {
    await expect(groupCount(page)).toHaveText('1 dead letter');
    const row = page.getByTestId(`dlq-row-${ref}`);
    await expect(row).toContainText('input');
    await expect(row).toContainText('poison payload');
    // When it was dead-lettered, its size and whether it waits or is replaying.
    await expect(page.getByTestId(`dlq-at-${ref}`)).toContainText(/now|ago/);
    await expect(row).toContainText(/\d+ B/);
    await expect(page.getByTestId(`dlq-state-${ref}`)).toHaveText('Waiting');
    await expect(page.getByTestId('dlq-total-bytes')).toContainText(/\d+(\.\d)? [KM]?B/);
    await expect(statTerm(page)).toHaveCSS('text-transform', 'none');
    await expect(statTerm(page)).toHaveCSS('overflow-wrap', 'anywhere');

    await page.getByTestId('dlq-filter').fill('no_such_relay_class');
    await expect(page.getByTestId('dlq-empty')).toContainText(
      'None waits for that relay class.',
    );
    await expect(group(page)).toHaveCount(0);

    await page.getByTestId('dlq-filter').fill('');
    await expect(group(page)).toBeVisible();
    await expect(page.getByTestId('dlq-empty')).toHaveCount(0);

    await menuAction(page, `dlq-menu-${ref}`, `dlq-inspect-${ref}`);
    await expect(page.getByTestId('inspector-entry')).toBeVisible();
    await expect(page.getByTestId('inspector-payload')).toContainText('poison');
    await page.getByTestId('inspector-close').click();
    await expect(page.getByTestId('inspector-entry')).toHaveCount(0);
  });

  test('a dead letter marked seen leaves the listing, and Show seen lists it badged', async ({ page }) => {
    await openQueue(page, { seen: false });
    await menuAction(page, `dlq-menu-${ref}`, `dlq-mark-seen-${ref}`);
    await expect(page.getByTestId(`dlq-row-${ref}`)).toHaveCount(0);
    await expect(page.getByTestId('dlq-empty')).toContainText('Show seen lists them');

    await page.getByTestId('dlq-show-seen').check();
    await expect(page).toHaveURL(/seen=shown/);
    await expect(page.getByTestId(`dlq-seen-${ref}`)).toHaveText('Seen');
    await expect(groupCount(page)).toHaveText('1 dead letter, 1 seen');
  });

  test('a replay is confirm-gated, and one that fails again is a dead letter of the next generation', async ({
    page,
  }) => {
    await menuAction(page, `dlq-menu-${ref}`, `dlq-replay-${ref}`);
    await expect(page.getByTestId('dlq-confirm-modal')).toContainText('Re-send');
    await page.getByTestId('dlq-confirm-cancel').click();
    await expect(page.getByTestId('dlq-confirm-modal')).toHaveCount(0);
    await expect(page.getByTestId('replay-pending')).toHaveCount(0);
    await expect(page.getByTestId(`dlq-row-${ref}`)).toBeVisible();

    await menuAction(page, `dlq-menu-${ref}`, `dlq-replay-${ref}`);
    await page.getByTestId('dlq-confirm-submit').click();
    await expect(page.getByTestId('replay-reparked')).toContainText('generation 2');
    // A new generation is not the one marked seen.
    await expect(page.getByTestId(`dlq-seen-${ref}`)).toHaveCount(0);
  });

  test('a drop is confirm-gated, and confirming removes the entry for good', async ({ page }) => {
    await menuAction(page, `dlq-menu-${ref}`, `dlq-drop-${ref}`);
    await expect(page.getByTestId('dlq-confirm-modal')).toContainText('permanent');
    await page.getByTestId('dlq-confirm-cancel').click();
    await expect(page.getByTestId('dlq-confirm-modal')).toHaveCount(0);
    await expect(page.getByTestId(`dlq-row-${ref}`)).toBeVisible();

    await menuAction(page, `dlq-menu-${ref}`, `dlq-drop-${ref}`);
    await page.getByTestId('dlq-confirm-submit').click();
    await expect(page.getByTestId(`dlq-row-${ref}`)).toHaveCount(0);
  });
});
