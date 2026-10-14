import { test, expect, clearStoredToken, openSettings } from './fixtures';

/**
 * The controller's authorization posture, and the token this UI presents.
 *
 * The dev stack claims its own bootstrap and issues a `_system` service token,
 * so an enforced posture with a bound principal is the state to assert rather
 * than to arrange. The other postures, and the token never reaching the page,
 * are covered in `test/flezha_ui_web/live/authz_posture_test.exs`.
 */
test('the service token binds the principal the top bar names, on an enforced controller', async ({
  page,
  live,
}) => {
  await live('/');

  const identity = page.getByTestId('authz-identity');
  await expect(identity).toContainText('_system');
  await expect(page.getByTestId('authz-unbound')).toHaveCount(0);
  await expect(page.getByTestId('authz-bootstrap-pending')).toHaveCount(0);

  await live('/controller');
  await expect(page.getByTestId('authz-posture')).toContainText('Enforced');
  // The "authorization is disabled" call-out belongs to an open controller.
  await expect(page.getByTestId('authz-open')).toHaveCount(0);

  await openSettings(page);
  const binding = page.getByTestId('flezha-token-binding');
  await expect(binding).toContainText('the service token is used');
  await expect(binding).toContainText('_system');
});

/**
 * Driven end to end because the two defects this caught — a form that POSTed
 * against a PUT route, and a refusal that has to reach the graph — are both
 * invisible to a controller test that calls the action directly.
 */
test('a stored token that does not verify is never rendered back, and its refusals are stated', async ({
  page,
  live,
}) => {
  const BAD_TOKEN = 'flz_e2e_deliberately_invalid';

  try {
    await openSettings(page);
    await page.locator('#flezha_token_token').fill(BAD_TOKEN);
    await page.locator('#update_flezha_token button').click();

    const binding = page.getByTestId('flezha-token-binding');
    await expect(binding).toContainText('Stored for you');
    // The controller's own verdict on the token, with its code.
    await expect(binding).toContainText('authz.token_malformed');
    // The credential itself must not reach the page, only the fact of it.
    await expect(page.locator('body')).not.toContainText(BAD_TOKEN);
    expect(await page.locator('#flezha_token_token').inputValue()).toBe('');

    const banner = page.getByTestId('authz-unbound');
    await expect(banner).toContainText('will be refused');

    // The controller narrows every listing to the caller, so with no identity
    // the dashboard states the refusal and where to fix it, rather than
    // rendering as an empty controller.
    await live('/');
    const refused = page.getByTestId('runtime-error');
    await expect(refused).toContainText('authz.principal_not_bound');
    await expect(refused.getByRole('link', { name: /settings/ })).toBeVisible();
  } finally {
    await clearStoredToken(page);
  }
});
