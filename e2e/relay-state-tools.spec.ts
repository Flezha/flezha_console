import {
  choose,
  menuAction,
  ownRelay,
  test,
  expect,
  sendRecords,
  type Page,
} from './fixtures';

/**
 * A relay's durable state from its state screen: its cells, their counters
 * and the point-in-time read, then maintaining it — a cell's outbox,
 * rotation, replay from a point in its history, deletion, and the class's
 * history retention.
 *
 * Every write lands on a relay this spec starts and stops itself, fed one
 * input so it has a cell: a flow relay, and a steps relay whose tasklet takes
 * a JSON string on its entry channel `in`. Its class is its run-unique id, so
 * the retention it sets reaches no other relay, and is put back all the same.
 */
/** The cell row of the relay's one cell, once it has been persisted. */
function cellRow(page: Page) {
  return page
    .locator('[data-testid^="cell-"]:not([data-testid^="cell-lagging-"]):not([data-testid^="cell-menu-"])')
    .first();
}

/** The cell's id, from its row's test id. */
async function cellOf(page: Page): Promise<string> {
  const row = cellRow(page);
  await expect(row).toBeVisible();
  return (await row.getAttribute('data-testid'))!.slice('cell-'.length);
}

const { id } = ownRelay('pw_state', { run: 'flow' });
const steps = ownRelay('pw_state_steps', { run: 'steps' });

test.beforeAll(() => sendRecords(id, ['state tools input']));
test.beforeAll(() => sendRecords(steps.id, ['"state tools turn"'], 'in'));

test.describe('Relay state tools', () => {
  test.beforeEach(async ({ live }) => {
    await live(`/namespaces/default/relays/${id}/state`);
  });

  test('a fed cell is listed under its tasklet, and read at the sequence it reports', async ({ page }) => {
    await expect(page.locator('[data-testid^="tasklet-"]').first()).toBeVisible();
    const row = cellRow(page);
    const walSeq = row.locator('td').nth(1);
    await expect(walSeq).toHaveText(/\d+/);
    const cell = (await row.getAttribute('data-testid'))!.slice('cell-'.length);

    await expect(page.getByTestId('history-retention')).toContainText(/\d+ hours/);
    await expect(page.getByTestId('finished-retention')).toHaveCount(0);

    await menuAction(page, `cell-menu-${cell}`, `select-${cell}`);
    await expect(page.getByTestId('time-travel')).toBeVisible();
    const seq = (await walSeq.innerText()).trim();
    await choose(page, 'travel-kind', 'seq');
    await page.getByTestId('travel-value').fill(seq);
    await page.getByTestId('travel-submit').click();

    await expect(page.getByTestId('travel-seq')).toHaveText(new RegExp(`\\b${seq}\\b`));
    await expect(page.getByTestId('travel-snapshot-size')).toBeVisible();
    await expect(page.getByTestId('travel-change-log-size')).toBeVisible();
  });

  test('a cell is inspected, rotated, replayed and deleted', async ({ page }) => {
    const cell = await cellOf(page);
    const walSeq = (await cellRow(page).locator('td').nth(1).innerText()).trim();

    // What each row action does is explained over the actions.
    const actions = page.locator('[data-testid$="-help-menu"]').first();
    await actions.click();
    await expect(actions).toHaveAttribute('aria-expanded', 'true');
    await expect(page.locator('[data-fcon-pop-panel]:visible')).toContainText(
      "Asks the cell's runner for a fresh snapshot and compacts the cell's write-ahead log behind it. The cell's state is kept.",
    );
    await page.keyboard.press('Escape');
    await expect(actions).toHaveAttribute('aria-expanded', 'false');

    // Selecting it reads its outbox.
    await menuAction(page, `cell-menu-${cell}`, `select-${cell}`);
    await expect(page.getByTestId('outbox').getByTestId('outbox-durable-seq')).toContainText(/\d+/);

    // Rotation asks first, naming the cell.
    await menuAction(page, `cell-menu-${cell}`, `rotate-${cell}`);
    await expect(page.getByTestId('state-confirm-modal')).toContainText(cell);
    await page.getByTestId('state-confirm-btn').click();
    await expect(page.getByText(`Compaction requested for ${cell}.`)).toBeVisible();

    // Replay takes time travel's target.
    await menuAction(page, `cell-menu-${cell}`, `select-${cell}`);
    await page.getByTestId('travel-value').fill(walSeq);
    await page.getByTestId('replay-open').click();
    await expect(page.getByTestId('state-confirm-modal')).toContainText('run again');
    await page.getByTestId('state-confirm-btn').click();
    await expect(page.getByTestId('replay-result')).toContainText(cell);

    // Deletion says it cannot be undone, and the row goes.
    await menuAction(page, `cell-menu-${cell}`, `delete-${cell}`);
    await expect(page.getByTestId('state-confirm-modal')).toContainText('cannot be recovered');
    await page.getByTestId('state-confirm-btn').click();
    await expect(page.getByTestId(`cell-${cell}`)).toHaveCount(0);
  });

  test('the class history retention is set, and put back', async ({ page }) => {
    const shown = page.getByTestId('history-retention');
    await expect(shown).toContainText(/\d+ hours/);
    const original = (await shown.innerText()).match(/(\d+) hours/)![1];

    for (const hours of [String(Number(original) + 1), original]) {
      await page.getByTestId('retention-hours').fill(hours);
      await page.getByTestId('retention-submit').click();
      await expect(shown).toContainText(`${hours} hours`);
    }
    await expect(page.getByTestId('retention-form')).toContainText('until the controller next boots');
  });
});

test.describe('Relay state tools on a steps cell', () => {
  test('a steps cell is read where its history stands, rotated and deleted', async ({ page, live }) => {
    await live(`/namespaces/default/relays/${steps.id}/state`);
    const cell = await cellOf(page);
    const walSeq = (await cellRow(page).locator('td').nth(1).innerText()).trim();

    await menuAction(page, `cell-menu-${cell}`, `select-${cell}`);
    await expect(page.getByTestId('outbox').getByTestId('outbox-durable-seq')).toContainText(/\d+/);
    await choose(page, 'travel-kind', 'seq');
    await page.getByTestId('travel-value').fill(walSeq);
    await page.getByTestId('travel-submit').click();
    await expect(page.getByTestId('travel-seq')).toHaveText(new RegExp(`\\b${walSeq}\\b`));
    // A steps relay is replayed by rewinding it, not from a cell.
    await expect(page.getByTestId('replay-open')).toHaveCount(0);

    await menuAction(page, `cell-menu-${cell}`, `rotate-${cell}`);
    await page.getByTestId('state-confirm-btn').click();
    await expect(page.getByText(`Compaction requested for ${cell}.`)).toBeVisible();

    await menuAction(page, `cell-menu-${cell}`, `delete-${cell}`);
    await page.getByTestId('state-confirm-btn').click();
    await expect(page.getByTestId(`cell-${cell}`)).toHaveCount(0);
  });
});
