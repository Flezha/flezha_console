import { test, expect } from './fixtures';

/**
 * Namespaces as declared objects: quota meters against live counters, and the
 * create/delete round-trip.
 *
 * `DevSetup` declares `default` with quota overrides, so its meters are real.
 * The created namespace is deleted in the same test, because the suite runs
 * against a shared controller and must leave it as it found it.
 */
test.describe('Namespace administration', () => {
  test('quota meters render against the controller’s live counters', async ({ page, live }) => {
    await live('/namespaces/default');

    await expect(page.getByTestId('quota-panel')).toBeVisible();
    // Declared, so limits apply and the "no declaration" state is absent.
    await expect(page.getByTestId('namespace-undeclared')).toHaveCount(0);

    for (const kind of ['operatives', 'runners', 'entities', 'mailbox_bytes', 'disk_bytes']) {
      await expect(page.getByTestId(`quota-${kind}`)).toBeVisible();
    }

    // A meter is drawn against a real limit, not a placeholder.
    await expect(page.getByTestId('quota-operatives')).toContainText(/of \d+/);
  });

  test('role bindings are listed read-only, naming flz for the write', async ({ page, live }) => {
    await live('/namespaces/default');

    await expect(page.getByTestId('role-bindings')).toBeVisible();

    const empty = page.getByTestId('role-bindings-empty');
    if (await empty.count()) {
      await expect(empty).toContainText('flz role bind');
    }
  });

  test('the listing marks a namespace as declared and running', async ({ page, live }) => {
    await live('/namespaces');

    await expect(page.getByTestId('namespace-row-default')).toBeVisible();
    await expect(page.getByTestId('namespace-state-default')).toContainText('declared');
  });

  test('creating a namespace and deleting it round-trips', async ({ page, live }) => {
    // Lowercase and hyphenated: the controller validates the name.
    const name = `e2e-tmp-${Date.now().toString(36)}`;

    await live('/namespaces');
    await page.getByTestId('create-namespace-btn').click();
    await page.getByTestId('create-namespace-name').fill(name);
    await page.getByTestId('create-max-operatives').fill('7');
    await page.getByTestId('create-namespace-submit').click();

    const row = page.getByTestId(`namespace-row-${name}`);
    await expect(row).toBeVisible();
    // Declared, with no hub running for it.
    await expect(page.getByTestId(`namespace-state-${name}`)).toContainText('no hub');
    await expect(page.getByTestId(`namespace-operatives-${name}`)).toHaveText(/^\s*0\s*$/);

    // The quota override reached the controller.
    await live(`/namespaces/${name}`);
    await expect(page.getByTestId('quota-operatives')).toContainText('of 7');

    await live('/namespaces');
    await page.getByTestId(`namespace-delete-${name}`).click();
    await page.getByTestId('delete-namespace-confirmation').fill(name);
    await page.getByTestId('delete-namespace-confirm').click();

    await expect(page.getByTestId(`namespace-row-${name}`)).toHaveCount(0);
  });

  test('delete is refused until the namespace is named exactly', async ({ page, live }) => {
    await live('/namespaces');
    await page.getByTestId('namespace-delete-default').click();

    // The confirm button stays disabled while the typed name does not match.
    await page.getByTestId('delete-namespace-confirmation').fill('not-default');
    await expect(page.getByTestId('delete-namespace-confirm')).toBeDisabled();

    await page.getByTestId('delete-namespace-cancel').click();
    await expect(page.getByTestId('delete-namespace-modal')).toHaveCount(0);
    // Still there, because nothing was confirmed.
    await expect(page.getByTestId('namespace-row-default')).toBeVisible();
  });
});
