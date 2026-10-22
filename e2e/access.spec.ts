import {
  test,
  expect,
  cliCall,
  clearStoredToken,
  openSection,
  openSettings,
  growListing,
  uniqueId,
} from './fixtures';

/**
 * Tokens and role bindings as the namespace screen lists them, and the controls
 * that follow the bound role.
 *
 * The console issues, revokes, binds and unbinds nothing: the controller keeps
 * those operations off the network, so each is made here through `cliCall()`,
 * the request `flz` sends, and the screen is read for what it lists.
 *
 * Tokens and bindings are made in the worker's own namespace, so no other
 * worker's rows redraw a listing a test reads. The viewer token is the
 * exception: it is issued in `default`, because the relay screen it is tried on
 * needs a relay, and only `default` has a runner to serve one. Each test undoes
 * what it made: a binding is removed and an issued token revoked. A revoked
 * token stays listed as revoked; the controller keeps no way to delete one.
 */
const nsUrl = (namespace: string) => `/namespaces/${namespace}`;

type Issued = { id: string; token: string };

/** Issues a token for `principal` holding `role` in `namespace`. */
async function issueToken(principal: string, namespace: string, role: string): Promise<Issued> {
  return (await cliCall('Namespace.issue_token', [
    principal,
    namespace,
    role,
    { ttl: 3600, label: 'playwright' },
  ])) as Issued;
}

const revokeToken = (id: string) => cliCall('Namespace.revoke_token', [id]);
const removeBinding = (principal: string) => cliCall('Namespace.unbind_role', [principal]);

test.describe('Tokens', () => {
  test('an issued token is listed without its value, and listed as revoked once revoked', async ({
    page,
    live,
    workerNamespace,
  }) => {
    const principal = uniqueId('pw_ci');
    let id = '';
    let revoked = false;

    try {
      id = (await issueToken(principal, workerNamespace, 'viewer')).id;

      await live(nsUrl(workerNamespace));
      await openSection(page, 'access');

      // Active tokens are listed soonest expiry first, so an hour's token
      // leads unless others expire sooner; it may still sit past the first page.
      await growListing(page, 'tokens-grid', page.getByTestId(`token-${id}`));
      await expect(page.getByTestId(`token-${id}`)).toContainText(principal);
      await expect(page.getByTestId(`token-status-${id}`)).toHaveText('Active');
      await expect(page.locator('body')).not.toContainText('flzt_');

      // When and by whom it was issued, and an expiry inside three days in
      // the warning tone.
      await expect(page.getByTestId(`token-issued-${id}`)).toContainText(/now|s ago/);
      await expect(page.getByTestId(`token-issuer-${id}`)).not.toHaveText('—');
      await expect(page.getByTestId(`token-expires-${id}`)).toContainText(/in \d+[hm]/);
      await expect(page.getByTestId(`token-expires-${id}`).locator('.fui-tone-warning')).toHaveCount(1);

      await revokeToken(id);
      revoked = true;

      // It leaves the Active listing and is found under Revoked, with when.
      await expect(page.getByTestId(`token-${id}`)).toHaveCount(0);
      await page.getByTestId('token-filter-revoked').click();
      await expect(page.getByTestId('token-filter-revoked')).toHaveAttribute('aria-pressed', 'true');
      await growListing(page, 'tokens-grid', page.getByTestId(`token-${id}`));
      await expect(page.getByTestId(`token-status-${id}`)).toHaveText('Revoked');
      await expect(page.getByTestId(`token-revoked-${id}`)).toContainText(/now|s ago/);
    } finally {
      if (id && !revoked) await revokeToken(id);
    }
  });
});

test.describe('Role bindings', () => {
  test('a bound principal is listed with when and by whom, and leaves the listing once unbound', async ({
    page,
    live,
    workerNamespace,
  }) => {
    const principal = uniqueId('pw_bound');
    let bound = false;

    try {
      await cliCall('Namespace.bind_role', [principal, 'viewer', workerNamespace]);
      bound = true;

      await live(nsUrl(workerNamespace));
      await openSection(page, 'access');
      await growListing(page, 'role-bindings-grid', page.getByTestId(`role-binding-${principal}`));
      await expect(page.getByTestId(`role-${principal}-viewer`)).toBeVisible();
      await expect(page.getByTestId(`binding-bound-${principal}`)).toContainText(/now|s ago/);
      await expect(page.getByTestId(`binding-by-${principal}`)).not.toHaveText('—');

      await removeBinding(principal);
      bound = false;
      await expect(page.getByTestId(`role-binding-${principal}`)).toHaveCount(0);
    } finally {
      if (bound) await removeBinding(principal);
    }
  });
});

test.describe('Controls follow the role', () => {
  // Which control each role loses on each screen is asserted in
  // `role_gating_test.exs`; here, that a real viewer token stored on the
  // worker's user reaches the controller and a screen follows its answer.
  test('a stored viewer token is answered as a viewer, and the relay screen offers it no mutation control', async ({
    page,
    live,
  }) => {
    const principal = uniqueId('pw_viewer');
    let id = '';

    try {
      const issued = await issueToken(principal, 'default', 'viewer');
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
    } finally {
      await clearStoredToken(page);
      if (id) await revokeToken(id);
    }
  });
});
