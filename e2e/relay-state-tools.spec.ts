import {
  menuAction,
  test,
  expect,
  openSection,
  startRelay,
  stopRelay,
  uniqueId,
  withStepsRelay,
  type Page,
  sendToRelay,
} from './fixtures';

/**
 * Maintaining a relay's persisted state from its state screen: a cell's
 * outbox, rotation, replay from a point in its history, deletion, and the
 * class's history retention; and the input log's retained records.
 *
 * Every write lands on a relay this spec starts and stops itself, fed one
 * input so it has a cell — never on a seeded relay, whose state other specs
 * read. The retention it changes is put back.
 */
/** The cell row of the relay's one cell, once it has been persisted. */
function cellRow(page: Page) {
  return page
    .locator('[data-testid^="cell-"]:not([data-testid^="cell-lagging-"]):not([data-testid^="cell-menu-"])')
    .first();
}

test.describe('Relay state tools', () => {
  test('a cell is inspected, rotated, replayed and deleted', async ({ page, live }) => {
    const id = uniqueId('pw_state');
    await live('/namespaces/default');
    await startRelay(page, id, { run: 'flow' });

    try {
      await live(`/namespaces/default/relays/${id}`);
      await sendToRelay(page, 'state tools input');

      await live(`/namespaces/default/relays/${id}/state`);
      const row = cellRow(page);
      await expect(row).toBeVisible({ timeout: 20_000 });
      const cell = (await row.getAttribute('data-testid'))!.slice('cell-'.length);
      const walSeq = (await row.locator('td').nth(1).innerText()).trim();

      // Selecting it reads its outbox.
      await menuAction(page, `cell-menu-${cell}`, `select-${cell}`);
      await expect(page.getByTestId('outbox').getByTestId('outbox-durable-seq')).toContainText(/\d+/);

      // Each write asks first; cancelling one does nothing.
      for (const control of [`rotate-${cell}`, `delete-${cell}`]) {
        await menuAction(page, `cell-menu-${cell}`, control);
        await expect(page.getByTestId('state-confirm-modal')).toContainText(cell);
        await page.getByTestId('state-confirm-cancel').click();
        await expect(page.getByTestId('state-confirm-modal')).toHaveCount(0);
      }
      await expect(page.getByTestId(`cell-${cell}`)).toBeVisible();
      await expect(page.getByText(`Compaction requested for ${cell}.`)).toHaveCount(0);

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
      await page.getByTestId('state-confirm-cancel').click();
      await expect(page.getByTestId('replay-result')).toHaveCount(0);
      await page.getByTestId('replay-open').click();
      await page.getByTestId('state-confirm-btn').click();
      await expect(page.getByTestId('replay-result')).toContainText(cell);

      // Deletion says it cannot be undone, and the row goes.
      await menuAction(page, `cell-menu-${cell}`, `delete-${cell}`);
      await expect(page.getByTestId('state-confirm-modal')).toContainText('cannot be recovered');
      await page.getByTestId('state-confirm-btn').click();
      await expect(page.getByTestId(`cell-${cell}`)).toHaveCount(0, { timeout: 15_000 });
    } finally {
      await live('/namespaces/default');
      await stopRelay(page, id);
    }
  });

  test('the history retention is set and put back', async ({ page, live }) => {
    await live('/namespaces/default/relays/testnet_store_1/state');

    const shown = page.getByTestId('history-retention');
    await expect(shown).toContainText(/\d+ hours/);
    const original = (await shown.innerText()).match(/(\d+) hours/)![1];
    const changed = String(Number(original) + 1);

    await expect(page.getByTestId('state-retention')).toContainText('History retention');

    // A negative number of hours is refused on the form and nothing is set.
    await page.getByTestId('retention-form').getByTestId('retention-hours').fill('-3');
    await page.getByTestId('retention-submit').click();
    await expect(page.getByTestId('retention-error')).toBeVisible();
    await expect(shown).toContainText(`${original} hours`);

    try {
      await page.getByTestId('retention-hours').fill(changed);
      await page.getByTestId('retention-submit').click();
      await expect(shown).toContainText(`${changed} hours`);
      await expect(page.getByTestId('retention-form')).toContainText('until the controller next boots');
    } finally {
      await page.getByTestId('retention-hours').fill(original);
      await page.getByTestId('retention-submit').click();
      await expect(shown).toContainText(`${original} hours`);
    }
  });

  test('a durable steps relay lists its input log records on expanding', async ({ page, live }) => {
    await withStepsRelay(page, async (id) => {
      await live(`/namespaces/default/relays/${id}`);
      await sendToRelay(page, 'an input to retain');
      await live(`/namespaces/default/relays/${id}/state`);
      await openSection(page, 'input-log');

      const records = page.getByTestId('inbox-records');
      await expect(records.getByTestId('inbox-floor')).toContainText('Payloads are not shown.');
      // The input just sent is retained, with its size.
      await expect(records.locator('[data-testid^="inbox-entry-"]').first()).toContainText(/\d+ B/);
    });
  });
});
