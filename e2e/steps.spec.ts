import {
  ownRelay,
  test,
  expect,
  openSection,
  growListing,
  sendToRelay,
  stopRelay,
} from './fixtures';

/**
 * The steps panel, task journal and input log of a durable steps relay this
 * file starts for itself, and the run it leaves in the relay history once
 * stopped.
 *
 * Whether a steps relay suspends, or how many iterations its journal holds,
 * depends on inputs a browser cannot send yet, so those states are asserted in
 * ExUnit against the fake controller rather than read off the live stack.
 */
const { id } = ownRelay('pw_steps', { run: 'steps' });

test.describe('Steps relays', () => {
  test('a durable steps relay states its steps, retains an input, and rewinds', async ({
    page,
    live,
  }) => {
    await live(`/namespaces/default/relays/${id}`);
    await expect(page.getByTestId('relay-run')).toHaveText('A steps relay');

    // Its steps facts are sentences on State.
    await live(`/namespaces/default/relays/${id}/state`);
    const panel = page.getByTestId('steps-panel');
    await expect(panel).toBeVisible();
    await expect(page.getByTestId('steps-durable')).toContainText('It is durable');
    await expect(panel).toContainText(/exactly once|at least once/);
    await expect(page.getByTestId('steps-init-error')).toHaveCount(0);
    await expect(page.getByTestId('history-retention')).toContainText(/\d+ hours/);
    // The test app's factories declare no keep_finished, and the dev
    // controllers keep nothing by default.
    await expect(page.getByTestId('finished-retention')).toContainText('Not kept');

    // Nothing sent yet: nothing pending, and an empty log said in words,
    // never as an offset of -1.
    await openSection(page, 'input-log');
    await expect(page.getByTestId('input-log-undelivered')).toHaveText(/^\s*0\s*$/);
    await expect(page.getByTestId('input-log-last-offset')).toHaveText(/^\s*no records\s*$/);

    await live(`/namespaces/default/relays/${id}`);
    await sendToRelay(page, 'hello');
    await live(`/namespaces/default/relays/${id}/state`);

    // The input just delivered is retained, with its size.
    await openSection(page, 'input-log');
    const records = page.getByTestId('inbox-records');
    await expect(records.getByTestId('inbox-floor')).toContainText('Payloads are not shown.');
    await expect(records.locator('[data-testid^="inbox-entry-"]').first()).toContainText(/\d+ B/);

    await openSection(page, 'journal');
    await expect(page.getByTestId('task-journal-committed')).toContainText('Committed iterations');
    await expect(page.getByTestId('task-journal-outcome')).toContainText('The run has not ended yet.');

    const open = page.getByTestId('open-rewind-btn');
    await open.click();
    await expect(page.getByTestId('rewind-modal')).toBeVisible();
    const iteration = await page.getByTestId('rewind-iteration').inputValue();
    await page.getByTestId('rewind-cancel-btn').click();
    await expect(page.getByTestId('rewind-modal')).toHaveCount(0);
    await expect(page.locator('body')).not.toContainText('Rewound to iteration');

    await open.click();
    await page.getByTestId('rewind-confirm-btn').click();
    await expect(page.getByTestId('rewind-modal')).toHaveCount(0);
    await expect(page.locator('body')).toContainText(`Rewound to iteration ${iteration}.`);
  });

  test("a stopped steps relay is listed among the namespace's recent runs, and opens on its last run", async ({
    page,
    live,
  }) => {
    await stopRelay(page, id);

    await live('/namespaces/default');
    await openSection(page, 'recent-runs');
    const row = page.getByTestId(`run-row-${id}`);
    // Other workers' runs end too, so this one may sit past the first page.
    await growListing(page, 'recent-runs', row);
    await expect(row).toContainText(`${id} finished: stopped`);

    // The listing stays live, so a run ending elsewhere can move this row
    // under a click: the link is followed by its address.
    const link = row.getByRole('link', { name: id, exact: true });
    await expect(link).toHaveAttribute('href', new RegExp(`/relays/${id}$`));
    await live((await link.getAttribute('href'))!);
    await expect(page.getByTestId('finished-outcome')).toContainText('stopped');
    await expect(page.getByTestId('finished-state')).toContainText('state was not kept');

    // Actions that need a live relay are absent rather than failing.
    await expect(page.getByTestId('task-journal-panel')).toHaveCount(0);
    await expect(page.getByTestId('stop-relay-btn')).toHaveCount(0);
  });
});
