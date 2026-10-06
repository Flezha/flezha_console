import {
  test,
  expect,
  clearStoredToken,
  openSection,
  openSettings,
  uniqueId,
  type Page,
} from './fixtures';

/**
 * Tokens and role bindings from the namespace screen, and the controls that
 * follow the bound role.
 *
 * The dev user presents the service token, which is `admin@_system`, so every
 * write here is allowed. Each test leaves what it made behind it undone: a
 * binding is removed, an issued token revoked, and the service token is left in
 * charge. A revoked token stays listed as revoked; the controller keeps no way
 * to delete one.
 */
const NS_URL = '/namespaces/default';

/** Issues a token from the namespace screen and answers its id and value. */
async function issueToken(page: Page, principal: string, role: string) {
  await openSection(page, 'tokens');
  await page.getByTestId('issue-token-btn').click();
  await page.getByTestId('issue-token-principal').fill(principal);
  await page.getByTestId('issue-token-role').fill(role);
  await page.getByTestId('issue-token-ttl').fill('3600');
  await page.getByTestId('issue-token-label').fill('playwright');
  await page.getByTestId('issue-token-submit').click();

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
  await openSection(page, 'tokens');
  const revoke = page.getByTestId(`revoke-token-${id}`);
  if ((await revoke.count()) === 0) return;

  await revoke.click();
  await page.getByTestId('revoke-token-confirm').click();
  await expect(page.getByTestId(`token-status-${id}`)).toHaveText('revoked');
}

/** Removes `principal`'s whole binding when it has one. Safe from `finally`. */
async function removeBinding(page: Page, live: (path: string) => Promise<void>, principal: string) {
  await live(NS_URL);
  await openSection(page, 'role-bindings');
  const remove = page.getByTestId(`unbind-binding-${principal}`);
  if ((await remove.count()) === 0) return;

  await remove.click();
  await page.getByTestId('unbind-role-confirm').click();
  await expect(page.getByTestId(`role-binding-${principal}`)).toHaveCount(0);
}

test.describe('Tokens', () => {
  test('a token is issued once, listed without its value, and revoked', async ({ page, live }) => {
    await live(NS_URL);
    const principal = uniqueId('pw_ci');
    let id = '';

    try {
      ({ id } = await issueToken(page, principal, 'viewer'));

      const row = page.getByTestId(`token-${id}`);
      await expect(row).toContainText(principal);
      await expect(page.getByTestId(`token-status-${id}`)).toHaveText('active');
      await expect(page.locator('body')).not.toContainText('flzt_');

      await page.getByTestId(`revoke-token-${id}`).click();
      await expect(page.getByTestId('revoke-token-modal')).toContainText(principal);
      await page.getByTestId('revoke-token-confirm').click();
      await expect(page.getByTestId(`token-status-${id}`)).toHaveText('revoked');
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
      await openSection(page, 'role-bindings');
      await page.getByTestId('bind-role-btn').click();
      await page.getByTestId('bind-role-principal').fill(principal);
      await page.getByTestId('bind-role-role').fill('viewer');
      await page.getByTestId('bind-role-submit').click();

      await expect(page.getByTestId(`role-${principal}-viewer`)).toBeVisible();

      await page.getByTestId(`unbind-role-${principal}-viewer`).click();
      await expect(page.getByTestId('unbind-role-modal')).toContainText(principal);
      await page.getByTestId('unbind-role-confirm').click();
      await expect(page.getByTestId(`role-${principal}-viewer`)).toHaveCount(0);
    } finally {
      await removeBinding(page, live, principal);
    }
  });

  test('an unknown role is refused with the roles there are', async ({ page, live }) => {
    await live(NS_URL);
    await openSection(page, 'role-bindings');
    await page.getByTestId('bind-role-btn').click();
    await page.getByTestId('bind-role-principal').fill(uniqueId('pw_nobody'));
    await page.getByTestId('bind-role-role').fill('overlord');
    await page.getByTestId('bind-role-submit').click();

    await expect(page.getByTestId('bind-role-error')).toContainText('authz.unknown_role');
  });
});

test.describe('Controls follow the role', () => {
  test('a viewer token renders no mutation control', async ({ page, live }) => {
    await live(NS_URL);
    const principal = uniqueId('pw_viewer');
    let id = '';

    try {
      const issued = await issueToken(page, principal, 'viewer');
      id = issued.id;

      await openSettings(page);
      await page.locator('#flezha_token_token').fill(issued.token);
      await page.locator('#update_flezha_token button').click();
      await expect(page.getByTestId('flezha-token-binding')).toContainText(principal);

      await live('/namespaces/default/relays/testnet_store_1');
      await expect(page.getByTestId('diagnose-btn')).toBeVisible();
      for (const control of ['stop-relay-btn', 'talk-open-btn', 'attach-plugin-btn']) {
        await expect(page.getByTestId(control)).toHaveCount(0);
      }

      await live(NS_URL);
      await expect(page.getByTestId('start-relay-btn')).toHaveCount(0);
      await expect(page.getByTestId('bind-role-btn')).toHaveCount(0);
      await expect(page.getByTestId('issue-token-btn')).toHaveCount(0);

      await live('/namespaces/default/plugins');
      await expect(page.getByTestId('enable-plugin-btn')).toHaveCount(0);
    } finally {
      await clearStoredToken(page);
      if (id) await revokeToken(page, live, id);
    }
  });
});
