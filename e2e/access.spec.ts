import {
  test,
  expect,
  clearStoredToken,
  menuAction,
  openSection,
  openSettings,
  uniqueId,
  visitLive,
  workerPage,
  type Page,
} from './fixtures';

/**
 * Tokens and role bindings from the namespace screen, and the controls that
 * follow the bound role.
 *
 * The worker's user presents the service token, which is `admin@_system`, so
 * every write here is allowed. Each test leaves what it made behind it undone: a
 * binding is removed, an issued token revoked, and the service token is left in
 * charge. A revoked token stays listed as revoked; the controller keeps no way
 * to delete one. The refused lifetime, the cancelled dialogs and the role list
 * are asserted in `test/flezha_ui_web/live/namespace_admin_test.exs` and
 * `shared_mechanics_test.exs`.
 */
const NS_URL = '/namespaces/default';

/** Opens the issue dialog, fills it and submits it, without judging the answer. */
async function submitIssue(page: Page, principal: string, role: string) {
  await page.getByTestId('issue-token-btn').click();
  await expect(page.getByTestId('issue-token-modal')).toBeVisible();
  await page.getByTestId('issue-token-principal').fill(principal);
  await page.getByTestId(`issue-token-role-${role}`).check();
  await page.getByTestId('issue-token-ttl').fill('3600');
  await page.getByTestId('issue-token-label').fill('playwright');
  await page.getByTestId('issue-token-submit').click();
}

/** Issues a token from the namespace screen and answers its id and value. */
async function issueToken(page: Page, principal: string, role: string) {
  await openSection(page, 'access');
  await submitIssue(page, principal, role);

  const value = page.getByTestId('issued-token-value');
  await expect(value).toBeVisible();
  const token = (await value.innerText()).trim();
  const id = (await page.getByTestId('issued-token-id').innerText()).trim();

  await page.getByTestId('issued-token-done').click();
  await expect(page.getByTestId('issue-token-modal')).toHaveCount(0);

  return { id, token };
}

/** Revokes `id` when it is still active. Safe from `finally`. */
async function revokeToken(page: Page, live: (path: string) => Promise<void>, id: string) {
  await live(NS_URL);
  await openSection(page, 'access');
  // A revoked token keeps its row but offers no revoke.
  if ((await page.getByTestId(`revoke-token-${id}`).count()) === 0) return;

  await menuAction(page, `token-menu-${id}`, `revoke-token-${id}`);
  await page.getByTestId('revoke-token-confirm').click();
  await expect(page.getByTestId(`token-status-${id}`)).toHaveText('Revoked');
}

/** Removes `principal`'s whole binding when it has one. Safe from `finally`. */
async function removeBinding(page: Page, live: (path: string) => Promise<void>, principal: string) {
  await live(NS_URL);
  await openSection(page, 'access');
  if ((await page.getByTestId(`unbind-binding-${principal}`).count()) === 0) return;

  await menuAction(page, `binding-menu-${principal}`, `unbind-binding-${principal}`);
  await page.getByTestId('unbind-role-confirm').click();
  await expect(page.getByTestId(`role-binding-${principal}`)).toHaveCount(0);
}

test.describe('Tokens', () => {
  test('a token is issued once, listed without its value, and revoked', async ({ page, live }) => {
    await live(NS_URL);
    await openSection(page, 'access');
    const principal = uniqueId('pw_ci');
    let id = '';

    try {
      await submitIssue(page, principal, 'viewer');

      await expect(page.getByTestId('issued-token')).toContainText('shown once');
      await expect(page.getByTestId('issued-token-value')).toHaveText(/\S{16,}/);
      await expect(page.getByTestId('issued-token-copy')).toBeVisible();
      id = (await page.getByTestId('issued-token-id').innerText()).trim();
      await page.getByTestId('issued-token-done').click();
      await expect(page.getByTestId('issue-token-modal')).toHaveCount(0);

      // Reopening the dialog asks again; the value is gone for good.
      await page.getByTestId('issue-token-btn').click();
      await expect(page.getByTestId('issued-token')).toHaveCount(0);
      await page.getByTestId('issue-token-cancel').click();

      await expect(page.getByTestId(`token-${id}`)).toContainText(principal);
      await expect(page.getByTestId(`token-status-${id}`)).toHaveText('Active');
      await expect(page.locator('body')).not.toContainText('flzt_');

      await menuAction(page, `token-menu-${id}`, `revoke-token-${id}`);
      await expect(page.getByTestId('revoke-token-modal')).toContainText(principal);
      await page.getByTestId('revoke-token-confirm').click();
      await expect(page.getByTestId(`token-status-${id}`)).toHaveText('Revoked');
    } finally {
      if (id) await revokeToken(page, live, id);
    }
  });
});

test.describe('Role bindings', () => {
  test('a principal is bound to a role and unbound again', async ({ page, live }) => {
    await live(NS_URL);
    const principal = uniqueId('pw_bound');

    try {
      await openSection(page, 'access');
      await page.getByTestId('bind-role-btn').click();
      await page.getByTestId('bind-role-principal').fill(principal);
      await page.getByTestId('bind-role-role-viewer').check();
      await page.getByTestId('bind-role-submit').click();

      await expect(page.getByTestId(`role-${principal}-viewer`)).toBeVisible();

      await menuAction(page, `binding-menu-${principal}`, `unbind-role-${principal}-viewer`);
      await expect(page.getByTestId('unbind-role-modal')).toContainText(principal);
      await page.getByTestId('unbind-role-confirm').click();
      await expect(page.getByTestId(`role-${principal}-viewer`)).toHaveCount(0);
    } finally {
      await removeBinding(page, live, principal);
    }
  });
});

test.describe('Controls follow the role', () => {
  // One viewer token, stored on the worker's user for the whole describe and
  // taken off again after it, so each screen group fails under its own name.
  let viewer: Page;
  let id = '';
  let principal = '';

  test.beforeAll(async ({ browser }, testInfo) => {
    viewer = await workerPage(browser, testInfo);
    const live = (path: string) => visitLive(viewer, path);
    principal = uniqueId('pw_viewer');

    await live(NS_URL);
    const issued = await issueToken(viewer, principal, 'viewer');
    id = issued.id;

    await openSettings(viewer);
    await viewer.locator('#flezha_token_token').fill(issued.token);
    await viewer.locator('#update_flezha_token button').click();
    await expect(viewer.getByTestId('flezha-token-binding')).toContainText(principal);
  });

  test.afterAll(async () => {
    await clearStoredToken(viewer);
    if (id) await revokeToken(viewer, (path) => visitLive(viewer, path), id);
    await viewer.context().close();
  });

  test('a viewer gets no mutation control on a relay or its state', async ({ page, live }) => {
    await live('/namespaces/default/relays/testnet_store_1');
    await expect(page.getByTestId('diagnose-btn')).toBeVisible();
    for (const control of ['stop-relay-btn', 'talk-open-btn', 'attach-plugin-btn']) {
      await expect(page.getByTestId(control)).toHaveCount(0);
    }

    await live('/namespaces/default/relays/testnet_store_1/state');
    await expect(page.getByTestId('retention-form')).toHaveCount(0);
    await expect(page.locator('[data-testid^="rotate-"]')).toHaveCount(0);
    await expect(page.locator('[data-testid^="delete-"]')).toHaveCount(0);
  });

  test('a viewer gets no mutation control on its namespace or its plugins', async ({ page, live }) => {
    await live(NS_URL);
    await expect(page.getByTestId('start-relay-btn')).toHaveCount(0);
    await expect(page.getByTestId('bind-role-btn')).toHaveCount(0);
    await expect(page.getByTestId('issue-token-btn')).toHaveCount(0);

    await live('/namespaces/default/plugins');
    await expect(page.getByTestId('enable-plugin-btn')).toHaveCount(0);
    await expect(page.locator('[data-testid^="plugin-disable-"]')).toHaveCount(0);
    await expect(page.locator('[data-testid^="plugin-unbind-"]')).toHaveCount(0);
  });

  test('a viewer gets no mutation control on the platform screens', async ({ page, live }) => {
    await live('/schedules');
    await expect(page.getByTestId('schedule-new-btn')).toHaveCount(0);

    await live('/audit');
    await expect(page.getByTestId('audit-rotate-btn')).toHaveCount(0);

    await live('/cluster');
    await expect(page.locator('[data-testid^="drop-runner-"]')).toHaveCount(0);

    await live('/controller');
    await expect(page.getByTestId('stop-controller-btn')).toHaveCount(0);
  });
});
