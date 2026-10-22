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
 * file starts for itself, and the finished relay it leaves once stopped.
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
    await expect(page.getByTestId('finished-retention')).toContainText(/\d+ hours/);

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

  test('a stopped steps relay is listed as finished, with its completion record', async ({
    page,
    live,
  }) => {
    // A steps relay stops cooperatively, leaves the listing once it has
    // completed, and completes as cancelled.
    await stopRelay(page, id);

    await live('/namespaces/default');
    await openSection(page, 'finished-relays');
    await page.getByTestId('reload-finished').click();
    const row = page.getByTestId(`finished-row-${id}`);
    // Finished relays stay listed for their retention window, so this one may
    // sit past the first page.
    await growListing(page, 'finished', row);
    await expect(row).toContainText('Cancelled');
    await expect(row).toContainText('steps');
    await expect(page.getByTestId(`finished-at-${id}`)).toContainText(/now|s ago/);
    // Kept until the end of the retention window the controller computed.
    await expect(page.getByTestId(`finished-kept-${id}`)).toContainText(/\bin \d/);

    await row.getByRole('link').click();
    await expect(page).toHaveURL(new RegExp(`/relays/${id}$`));
    await expect(page.getByTestId('completion-record')).toContainText('Cancelled');

    // Actions that need a live relay are absent rather than failing.
    await expect(page.getByTestId('task-journal-panel')).toHaveCount(0);
    await expect(page.getByTestId('stop-relay-btn')).toHaveCount(0);
  });
});
