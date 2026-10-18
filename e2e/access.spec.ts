import {
  test,
  expect,
  clearStoredToken,
  menuAction,
  openSection,
  openSettings,
  growListing,
  liveViewFrame,
  uniqueId,
  visitLive,
  workerPage,
  type Page,
} from './fixtures';

/**
 * Tokens and role bindings from the namespace screen, and the controls that
 * follow the bound role.
 *
 * Tokens and bindings are made in the worker's own namespace, so no other
 * worker's rows redraw a listing a test acts on. The viewer token is the
 * exception: it is issued in `default`, because the relay screen it is tried
 * on needs a relay, and only `default` has a runner to serve one.
 *
 * The worker's user presents the service token, which is `admin@_system`, so
 * every write here is allowed. Each test leaves what it made behind it undone: a
 * binding is removed, an issued token revoked, and the service token is left in
 * charge. A revoked token stays listed as revoked; the controller keeps no way
 * to delete one. The refused lifetime, the cancelled dialogs and the role list
 * are asserted in `test/flezha_ui_web/live/namespace_admin_test.exs` and
 * `shared_mechanics_test.exs`.
 */
const nsUrl = (namespace: string) => `/namespaces/${namespace}`;

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

/**
 * How far, in pixels, the open menu `id` sits from where it hangs off its
 * trigger: 4 px below it, or 4 px above it when it opened upward.
 */
function menuOffset(page: Page, id: string): Promise<number> {
  return page.evaluate((id) => {
    const pop = document.getElementById(id)!;
    const trigger = pop.querySelector(':scope > [data-fui-pop-trigger]')!.getBoundingClientRect();
    const panel = pop.querySelector(':scope > [data-fui-pop-panel]')!.getBoundingClientRect();
    return Math.min(Math.abs(panel.top - trigger.bottom - 4), Math.abs(trigger.top - panel.bottom - 4));
  }, id);
}

/** Binds `principal` to the viewer role from the namespace screen that is open. */
async function bindViewer(page: Page, principal: string) {
  await openSection(page, 'access');
  await page.getByTestId('bind-role-btn').click();
  await page.getByTestId('bind-role-principal').fill(principal);
  await page.getByTestId('bind-role-role-viewer').check();
  await page.getByTestId('bind-role-submit').click();
  await growListing(page, 'role-bindings-grid', page.getByTestId(`role-binding-${principal}`));
  await expect(page.getByTestId(`role-${principal}-viewer`)).toBeVisible();
}

/** Revokes `id` in `namespace` when it is still active. Safe from `finally`. */
async function revokeToken(page: Page, live: (path: string) => Promise<void>, namespace: string, id: string) {
  await live(nsUrl(namespace));
  await openSection(page, 'access');
  await growListing(page, 'tokens-grid', page.getByTestId(`token-${id}`));
  // The listing shows active tokens, so a revoked one is not offered at all.
  if ((await page.getByTestId(`revoke-token-${id}`).count()) === 0) return;

  await menuAction(page, `token-menu-${id}`, `revoke-token-${id}`);
  await page.getByTestId('revoke-token-confirm').click();
  await expect(page.getByTestId(`token-${id}`)).toHaveCount(0);
}

/** Removes `principal`'s whole binding in `namespace` when it has one. Safe from `finally`. */
async function removeBinding(
  page: Page,
  live: (path: string) => Promise<void>,
  namespace: string,
  principal: string,
) {
  await live(nsUrl(namespace));
  await openSection(page, 'access');
  await growListing(page, 'role-bindings-grid', page.getByTestId(`role-binding-${principal}`));
  if ((await page.getByTestId(`unbind-binding-${principal}`).count()) === 0) return;

  await menuAction(page, `binding-menu-${principal}`, `unbind-binding-${principal}`);
  await page.getByTestId('unbind-role-confirm').click();
  await expect(page.getByTestId(`role-binding-${principal}`)).toHaveCount(0);
}

test.describe('Tokens', () => {
  test('a token is issued once, listed without its value, and revoked', async ({ page, live, workerNamespace }) => {
    await live(nsUrl(workerNamespace));
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

      await menuAction(page, `token-menu-${id}`, `revoke-token-${id}`);
      await expect(page.getByTestId('revoke-token-modal')).toContainText(principal);
      await page.getByTestId('revoke-token-confirm').click();

      // It leaves the Active listing and is found under Revoked, with when.
      await expect(page.getByTestId(`token-${id}`)).toHaveCount(0);
      await page.getByTestId('token-filter-revoked').click();
      await expect(page.getByTestId('token-filter-revoked')).toHaveAttribute('aria-pressed', 'true');
      await growListing(page, 'tokens-grid', page.getByTestId(`token-${id}`));
      await expect(page.getByTestId(`token-status-${id}`)).toHaveText('Revoked');
      await expect(page.getByTestId(`token-revoked-${id}`)).toContainText(/now|s ago/);
    } finally {
      if (id) await revokeToken(page, live, workerNamespace, id);
    }
  });
});

test.describe('Role bindings', () => {
  test('a principal is bound to a role and unbound again', async ({ page, live, workerNamespace }) => {
    await live(nsUrl(workerNamespace));
    const principal = uniqueId('pw_bound');

    try {
      await bindViewer(page, principal);
      await expect(page.getByTestId(`binding-bound-${principal}`)).toContainText(/now|s ago/);
      await expect(page.getByTestId(`binding-by-${principal}`)).not.toHaveText('—');

      await menuAction(page, `binding-menu-${principal}`, `unbind-role-${principal}-viewer`);
      await expect(page.getByTestId('unbind-role-modal')).toContainText(principal);
      await page.getByTestId('unbind-role-confirm').click();
      await expect(page.getByTestId(`role-${principal}-viewer`)).toHaveCount(0);
    } finally {
      await removeBinding(page, live, workerNamespace, principal);
    }
  });

  test('an open binding menu stays open while the screen refreshes and another session binds, and acts on its own row', async ({
    page,
    live,
    browser,
    workerNamespace,
  }, testInfo) => {
    const mine = uniqueId('pw_mine');
    const theirs = uniqueId('pw_theirs');
    const other = await workerPage(browser, testInfo);

    // Every LiveView diff page A receives, so the test can wait for the
    // screen's own refresh to patch it rather than for time to pass.
    let diffs = 0;
    page.on('websocket', (socket) =>
      socket.on('framereceived', ({ payload }) => {
        if (liveViewFrame(payload)?.event === 'diff') diffs++;
      }),
    );

    try {
      await live(nsUrl(workerNamespace));
      await bindViewer(page, mine);

      const item = page.getByTestId(`unbind-role-${mine}-viewer`);
      await page.getByTestId(`binding-menu-${mine}`).click();
      await expect(item).toBeVisible();

      // Two refreshes patch the screen, each redrawing the "bound" times.
      const before = diffs;
      await expect.poll(() => diffs).toBeGreaterThanOrEqual(before + 2);
      await expect(item).toBeVisible();

      // Another session binds into the same listing while the menu is open.
      await visitLive(other, nsUrl(workerNamespace));
      await bindViewer(other, theirs);
      await expect(page.getByTestId(`role-binding-${theirs}`)).toBeVisible();
      await expect(item).toBeVisible();
      // It still hangs from its own row's trigger, wherever the new row landed.
      await expect.poll(() => menuOffset(page, `binding-menu-${mine}`)).toBeLessThanOrEqual(1);

      await item.click();
      await expect(page.getByTestId('unbind-role-modal')).toContainText(mine);
      await page.getByTestId('unbind-role-confirm').click();
      await expect(page.getByTestId(`role-binding-${mine}`)).toHaveCount(0);
      await expect(page.getByTestId(`role-${theirs}-viewer`)).toBeVisible();
    } finally {
      await other.context().close();
      await removeBinding(page, live, workerNamespace, mine);
      await removeBinding(page, live, workerNamespace, theirs);
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
      await live(nsUrl('default'));
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
    } finally {
      await clearStoredToken(page);
      if (id) await revokeToken(page, live, 'default', id);
    }
  });
});
