import {
  menuAction,
  ownRelay,
  test,
  expect,
  choose,
  sendRecords,
} from './fixtures';

/**
 * A relay's durable state: its cells, their counters, its retention and the
 * point-in-time read, on a flow relay this file starts and feeds itself.
 */
const { id } = ownRelay('pw_cells', { run: 'flow' });

test.beforeAll(() => sendRecords(id, ['a cell to read']));

test.describe('Relay durable state', () => {
  test('a fed cell is listed under its tasklet, and read at the sequence it reports', async ({
    page,
    live,
  }) => {
    await live(`/namespaces/default/relays/${id}/state`);

    await expect(page.locator('[data-testid^="tasklet-"]').first()).toBeVisible();
    const row = page
      .locator('[data-testid^="cell-"]:not([data-testid^="cell-lagging-"]):not([data-testid^="cell-menu-"])')
      .first();
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
});
