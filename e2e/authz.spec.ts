import { test, expect, clearStoredToken, openSettings } from './fixtures';

/**
 * The controller's authorization posture, and the token this UI presents.
 *
 * The dev stack claims its own bootstrap and issues a `_system` service token,
 * so an enforced posture with a bound principal is the state to assert rather
 * than to arrange. `bootstrap_pending` cannot be produced against a controller
 * that is already claimed — that banner is covered in
 * `test/flezha_ui_web/live/authz_posture_test.exs`.
 */
test.describe('Authorization posture', () => {
  test('the top bar names the bound principal, with no unbound banner', async ({ page, live }) => {
    await live('/');

    const identity = page.getByTestId('authz-identity');
    await expect(identity).toBeVisible();
    await expect(identity).toContainText('_system');

    await expect(page.getByTestId('authz-unbound')).toHaveCount(0);
    await expect(page.getByTestId('authz-bootstrap-pending')).toHaveCount(0);
  });

  test('the controller screen states that authorization is enforced', async ({ page, live }) => {
    await live('/controller');

    await expect(page.getByTestId('authz-posture')).toContainText('enforced');
    // The "authorization is disabled" call-out belongs to an open controller.
    await expect(page.getByTestId('authz-open')).toHaveCount(0);
  });
});

/**
 * Storing a personal token, and what the UI does when it does not verify.
 *
 * Driven end to end because the two defects this caught — a form that POSTed
 * against a PUT route, and a refusal that has to reach the graph — are both
 * invisible to a controller test that calls the action directly.
 */
test.describe('The flezha token in settings', () => {
  const BAD_TOKEN = 'flz_e2e_deliberately_invalid';

  test.afterEach(async ({ page }) => {
    // Leave the service token in charge, whatever the test did.
    await clearStoredToken(page);
  });

  test('with no personal token, the service token binds the identity', async ({ page }) => {
    await openSettings(page);

    const binding = page.getByTestId('flezha-token-binding');
    await expect(binding).toContainText('using the service token');
    await expect(binding).toContainText('Principal');
    await expect(binding).toContainText('_system');
  });

  test('the stored token is never rendered back', async ({ page }) => {
    await openSettings(page);

    await page.locator('#flezha_token_token').fill(BAD_TOKEN);
    await page.locator('#update_flezha_token button').click();

    await expect(page.getByTestId('flezha-token-binding')).toContainText('Stored for you');
    // The credential itself must not reach the page, only the fact of it.
    await expect(page.locator('body')).not.toContainText(BAD_TOKEN);
    expect(await page.locator('#flezha_token_token').inputValue()).toBe('');
  });

  test('a token that does not verify is explained, and refusals are stated', async ({
    page,
    live,
  }) => {
    await openSettings(page);
    await page.locator('#flezha_token_token').fill(BAD_TOKEN);
    await page.locator('#update_flezha_token button').click();

    // The controller's own verdict on the token, with its code.
    await expect(page.getByTestId('flezha-token-binding')).toContainText('authz.token_malformed');

    const banner = page.getByTestId('authz-unbound');
    await expect(banner).toBeVisible();
    await expect(banner).toContainText('will be refused');

    // The controller narrows every listing to the caller, so with no identity
    // the dashboard states the refusal and where to fix it, rather than
    // rendering as an empty controller.
    await live('/');
    const refused = page.getByTestId('runtime-error');
    await expect(refused).toContainText('authz.principal_not_bound');
    await expect(refused.getByRole('link', { name: /settings/ })).toBeVisible();
  });
});
