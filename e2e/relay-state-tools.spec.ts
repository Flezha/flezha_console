import {
  test,
  expect,
  openSection,
  startRelay,
  stopRelay,
  uniqueId,
  withStepsRelay,
  type Page,
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
/** Sends one raw message to the relay whose detail screen is open. */
async function feed(page: Page, payload: string): Promise<void> {
  await page.getByTestId('talk-open-btn').click();
  await page.getByTestId('talk-mode-raw').click();
  await page.getByTestId('talk-payload').fill(payload);
  await page.getByTestId('talk-send-btn').click();
  await expect(page.getByTestId('talk-result')).toContainText('Delivered to', { timeout: 20_000 });
  await page.getByTestId('talk-close-btn').click();
}

/** The cell row of the relay's one cell, once it has been persisted. */
function cellRow(page: Page) {
  return page.locator('[data-testid^="cell-"]:not([data-testid^="cell-lagging-"])').first();
}

test.describe('Relay state tools', () => {
  test('a cell is inspected, rotated, replayed and deleted', async ({ page, live }) => {
    const id = uniqueId('pw_state');
    await live('/namespaces/default');
    await startRelay(page, id, { run: 'flow' });

    try {
      await live(`/namespaces/default/relays/${id}`);
      await feed(page, 'state tools input');

      await live(`/namespaces/default/relays/${id}/state`);
      const row = cellRow(page);
      await expect(row).toBeVisible({ timeout: 20_000 });
      const cell = (await row.getAttribute('data-testid'))!.slice('cell-'.length);
      const walSeq = (await row.locator('td').nth(1).innerText()).trim();

      // Selecting it reads its outbox.
      await page.getByTestId(`select-${cell}`).click();
      await expect(page.getByTestId('outbox-durable-seq')).toContainText(/\d+/);

      // Rotation asks first, naming the cell.
      await page.getByTestId(`rotate-${cell}`).click();
      await expect(page.getByTestId('state-confirm-modal')).toContainText(cell);
      await page.getByTestId('state-confirm-btn').click();
      await expect(page.getByText(`Compaction requested for ${cell}.`)).toBeVisible();

      // Replay takes time travel's target.
      await page.getByTestId(`select-${cell}`).click();
      await page.getByTestId('travel-value').fill(walSeq);
      await page.getByTestId('replay-open').click();
      await expect(page.getByTestId('state-confirm-modal')).toContainText('run again');
      await page.getByTestId('state-confirm-btn').click();
      await expect(page.getByTestId('replay-result')).toContainText(cell);

      // Deletion says it cannot be undone, and the row goes.
      await page.getByTestId(`delete-${cell}`).click();
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
      await openSection(page, 'input-log');

      await expect(page.getByTestId('inbox-floor')).toContainText('Payloads are not shown.');
    });
  });
});
