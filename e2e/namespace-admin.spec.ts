import {
  menuAction,
  test,
  expect,
  openPage,
  openSection,
  startRelay,
  stopRelay,
  uniqueId,
  visitLive,
  type Page,
} from './fixtures';

/**
 * Namespaces as declared objects: quota meters against live counters, the
 * create/delete round-trip, and the finished relays and runners a namespace
 * lists. What the forms refuse before the controller, the role bindings and
 * the delete gate are asserted in `namespace_admin_test.exs`.
 *
 * `DevSetup` declares `default` with quota overrides, so its meters are real.
 * The created namespace is deleted in the same test, because the suite runs
 * against a shared controller and must leave it as it found it.
 */
/**
 * Deletes `name` from the listing, typing its name to confirm. Safe from
 * `finally`: a namespace already gone is left alone.
 */
async function deleteNamespace(page: Page, name: string): Promise<void> {
  await visitLive(page, '/namespaces');
  const row = page.getByTestId(`namespace-row-${name}`);
  if ((await row.count()) === 0) return;

  await menuAction(page, `namespace-menu-${name}`, `namespace-delete-${name}`);
  await expect(page.getByTestId('delete-namespace-modal')).toContainText(name);
  await page.getByTestId('delete-namespace-confirmation').fill(name);
  await page.getByTestId('delete-namespace-confirm').click();
  await expect(row).toHaveCount(0);
}

test.describe('Namespace administration', () => {
  test('quota meters render against the controller’s live counters', async ({ page, live }) => {
    await live('/namespaces/default');
    await openSection(page, 'quotas');

    await expect(page.getByTestId('quota-panel')).toBeVisible();
    // Declared, so limits apply and the "no declaration" state is absent.
    await expect(page.getByTestId('namespace-undeclared')).toHaveCount(0);

    for (const kind of ['relays', 'runners', 'cells', 'mailbox_bytes', 'disk_bytes']) {
      await expect(page.getByTestId(`quota-${kind}`)).toBeVisible();
    }

    // A meter is drawn against a real limit, not a placeholder.
    await expect(page.getByTestId('quota-relays')).toContainText(/of \d+/);
  });

  test('creating a namespace and deleting it round-trips', async ({ page, live }) => {
    // Lowercase and hyphenated: the controller validates the name.
    const name = `e2e-tmp-${Date.now().toString(36)}`;

    try {
      await live('/namespaces');
      await page.getByTestId('create-namespace-btn').click();
      await page.getByTestId('create-namespace-cancel').click();
      await expect(page.getByTestId('create-namespace-modal')).toHaveCount(0);
      await page.getByTestId('create-namespace-btn').click();
      await expect(page.getByTestId('create-namespace-modal')).toBeVisible();

      // The controller refuses a name it cannot take, and the form stays open.
      const nameField = page.getByTestId('create-namespace-form').getByTestId('create-namespace-name');
      await nameField.fill('Not A Valid Name!');
      await page.getByTestId('create-namespace-submit').click();
      await expect(page.getByTestId('create-namespace-error')).toContainText('namespace.');
      await expect(page.getByTestId('create-namespace-modal')).toBeVisible();

      await nameField.fill(name);
      await page.getByTestId('create-max-relays').fill('7');
      await page.getByTestId('create-max-runners').fill('3');
      await page.getByTestId('create-namespace-submit').click();
      await expect(page.getByTestId('create-namespace-modal')).toHaveCount(0);

      const row = page.getByTestId(`namespace-row-${name}`);
      await expect(row).toBeVisible();
      // Declared, with no hub running for it.
      await expect(page.getByTestId(`namespace-state-${name}`)).toContainText('no hub');
      await expect(page.getByTestId(`namespace-relays-${name}`)).toHaveText(/^\s*0 relays\s*$/);

      // The quota override reached the controller.
      await live(`/namespaces/${name}`);
      await openSection(page, 'quotas');
      await expect(page.getByTestId('quota-relays')).toContainText('of 7');
      await expect(page.getByTestId('quota-runners')).toContainText('of 3');

      // Editing a limit: a value that is not a whole number is refused on the
      // form, cancelling changes nothing, and saving reaches the meter.
      await page.getByTestId('edit-quotas-btn').click();
      await expect(page.getByTestId('quota-modal')).toBeVisible();
      await page.getByTestId('quota-input-max_relays').fill('-2');
      await page.getByTestId('quota-save').click();
      await expect(page.getByTestId('quota-error')).toContainText(
        'max_relays must be a whole number',
      );
      await page.getByTestId('quota-cancel').click();
      await expect(page.getByTestId('quota-modal')).toHaveCount(0);
      await expect(page.getByTestId('quota-relays')).toContainText('of 7');

      await page.getByTestId('edit-quotas-btn').click();
      await page.getByTestId('quota-input-max_relays').fill('9');
      await page.getByTestId('quota-save').click();
      await expect(page.getByTestId('quota-modal')).toHaveCount(0);
      await expect(page.getByTestId('quota-relays')).toContainText('of 9');

      await deleteNamespace(page, name);
    } finally {
      await deleteNamespace(page, name);
    }
  });

  test('the finished listing reloads on request, and the runners panel lists the runner', async ({
    page,
    live,
  }) => {
    const id = uniqueId('pw_fin');
    const other = await openPage(page, '/namespaces/default');

    try {
      await live('/namespaces/default');
      await startRelay(page, id, { run: 'steps' });
      await openSection(page, 'finished-relays');
      await stopRelay(other, id);

      await page.getByTestId('reload-finished').click();
      await expect(page.getByTestId(`finished-row-${id}`)).toContainText('Cancelled');
      await expect(page.getByTestId('finished-loading')).toHaveCount(0);

      await openSection(page, 'runners');
      await expect(page.getByTestId('runners-panel')).toContainText('Runners');
      // A long runner id is shortened on screen, so the row is read by its id.
      await expect(
        page.getByTestId('runners-default').locator('[data-testid^="runner-default_"]').first(),
      ).toBeVisible();
    } finally {
      await stopRelay(other, id);
      await other.close();
    }
  });
});
