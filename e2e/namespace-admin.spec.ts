import { test, expect, openSection, withStepsRelay } from './fixtures';

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

  test('role bindings are listed with the control that binds one', async ({ page, live }) => {
    await live('/namespaces/default');
    await openSection(page, 'role-bindings');

    await expect(page.getByTestId('role-bindings')).toBeVisible();
    await expect(page.getByTestId('bind-role-btn')).toBeVisible();
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
    await expect(page.getByTestId('create-namespace-modal')).toBeVisible();
    await page.getByTestId('create-namespace-form').getByTestId('create-namespace-name').fill(name);
    await page.getByTestId('create-max-relays').fill('7');
    await page.getByTestId('create-max-runners').fill('3');
    await page.getByTestId('create-namespace-submit').click();
    await expect(page.getByTestId('create-namespace-modal')).toHaveCount(0);

    const row = page.getByTestId(`namespace-row-${name}`);
    await expect(row).toBeVisible();
    // Declared, with no hub running for it.
    await expect(page.getByTestId(`namespace-state-${name}`)).toContainText('no hub');
    await expect(page.getByTestId(`namespace-relays-${name}`)).toHaveText(/^\s*0\s*$/);

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

    await live('/namespaces');
    await page.getByTestId(`namespace-delete-${name}`).click();
    await expect(page.getByTestId('delete-namespace-modal')).toContainText(name);
    await page.getByTestId('delete-namespace-confirmation').fill(name);
    await page.getByTestId('delete-namespace-confirm').click();

    await expect(page.getByTestId(`namespace-row-${name}`)).toHaveCount(0);
  });

  test('the create form refuses a bad quota and a bad name, and cancelling creates nothing', async ({
    page,
    live,
  }) => {
    const name = `e2e-bad-${Date.now().toString(36)}`;
    await live('/namespaces');

    await page.getByTestId('create-namespace-btn').click();
    await page.getByTestId('create-namespace-name').fill(name);
    await page.getByTestId('create-max-runners').fill('-1');
    await page.getByTestId('create-namespace-submit').click();
    await expect(page.getByTestId('create-namespace-error')).toContainText(
      'max_runners must be a whole number',
    );

    await page.getByTestId('create-max-runners').fill('');
    await page.getByTestId('create-namespace-name').fill('Not A Valid Name!');
    await page.getByTestId('create-namespace-submit').click();
    await expect(page.getByTestId('create-namespace-error')).toContainText('namespace.');
    await expect(page.getByTestId('create-namespace-modal')).toBeVisible();

    await page.getByTestId('create-namespace-cancel').click();
    await expect(page.getByTestId('create-namespace-modal')).toHaveCount(0);
    await expect(page.getByTestId(`namespace-row-${name}`)).toHaveCount(0);
  });

  test('the finished listing reloads on request, and the runners panel lists the runner', async ({
    page,
    live,
  }) => {
    // A steps relay this test starts and stops is a finished relay it can name.
    let stopped = '';
    await withStepsRelay(page, async (id) => {
      stopped = id;
    });

    await live('/namespaces/default');
    await openSection(page, 'finished-relays');
    await page.getByTestId('reload-finished').click();
    await expect(page.getByTestId('finished-loading')).toHaveCount(0, { timeout: 20_000 });
    await expect(page.getByTestId(`finished-row-${stopped}`)).toContainText('cancelled');

    await openSection(page, 'runners');
    await expect(page.getByTestId('runners-panel')).toContainText('Runners (');
    await expect(page.getByTestId('runners-default').locator('tbody tr').first()).toContainText(
      'default_',
    );
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
