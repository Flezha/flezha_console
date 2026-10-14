import {
  menuAction,
  ownRelay,
  test,
  expect,
  sendRecords,
  type Page,
} from './fixtures';

/**
 * Maintaining a relay's persisted state from its state screen: a cell's
 * outbox, rotation, replay from a point in its history, deletion, and the
 * class's history retention.
 *
 * Every write lands on a relay this spec starts and stops itself, fed one
 * input so it has a cell. Its class is its run-unique id, so the retention it
 * sets reaches no other relay, and is put back all the same.
 */
/** The cell row of the relay's one cell, once it has been persisted. */
function cellRow(page: Page) {
  return page
    .locator('[data-testid^="cell-"]:not([data-testid^="cell-lagging-"]):not([data-testid^="cell-menu-"])')
    .first();
}

const { id } = ownRelay('pw_state', { run: 'flow' });

test.beforeAll(() => sendRecords(id, ['state tools input']));

test.describe('Relay state tools', () => {
  test.beforeEach(async ({ live }) => {
    await live(`/namespaces/default/relays/${id}/state`);
  });

  test('a cell is inspected, rotated, replayed and deleted', async ({ page }) => {
    const row = cellRow(page);
    await expect(row).toBeVisible();
    const cell = (await row.getAttribute('data-testid'))!.slice('cell-'.length);
    const walSeq = (await row.locator('td').nth(1).innerText()).trim();

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
