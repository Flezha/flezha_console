import { cliCall, growListing, test, expect, openSection } from './fixtures';

/**
 * Namespaces as declared objects: quota meters against live counters, the
 * create and quota round-trip, and the runners a namespace lists; its finished
 * relays are read in `steps.spec.ts`. What the forms refuse before the
 * controller and the role bindings are asserted in `namespace_admin_test.exs`.
 *
 * `DevSetup` declares `default` with quota overrides, so its meters are real.
 * Every run adds its workers' namespaces to the listing, so a row is found by
 * growing the listing to it, and the runner row read is whichever the stack
 * runs, since no test adds or removes a runner.
 * The created namespace is deleted in the same test, because the suite runs
 * against a shared controller and must leave it as it found it. The console
 * deletes no namespace, so that is done through `cliCall()`, the request `flz`
 * sends.
 */

test.describe('Namespace administration', () => {
  test('quota meters render against the controller’s live counters, and the runners panel lists the runner', async ({
    page,
    live,
  }) => {
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

    await openSection(page, 'runners');
    await expect(page.getByTestId('runners-panel')).toContainText('Runners');
    // A long runner id is shortened on screen, so the row is read by its id.
    await expect(
      page.getByTestId('runners-default').locator('[data-testid^="runner-default_"]').first(),
    ).toBeVisible();
  });

  test('creating a namespace and changing its limits round-trips', async ({ page, live }) => {
    // Lowercase and hyphenated: the controller validates the name.
    const name = `e2e-tmp-${Date.now().toString(36)}`;
    let created = false;

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
      created = true;

      const row = page.getByTestId(`namespace-row-${name}`);
      await growListing(page, 'namespaces', row);
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
    } finally {
      if (created) await cliCall('Namespace.delete', [name]);
    }
  });
});
