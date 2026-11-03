import { test, expect, createConsoleUser, deleteConsoleUser, uniqueId } from './fixtures';
import { submitLogin } from './global-setup';

/**
 * An account made by the operator's command, from its first login through a
 * settings change to logging out, after which a visit is sent to the form and
 * the old password is refused, as a user the test makes for itself.
 *
 * Nothing here runs as a worker's user: changing its password or ending its
 * session would log the rest of that worker's specs out. The refusals of each
 * settings form, the missing registration route and the email links are
 * asserted in the `user_session` and `user_settings` controller tests.
 */
test.use({ storageState: { cookies: [], origins: [] } });

const PASSWORD = 'a long enough password';
const NEXT_PASSWORD = 'another long enough password';

test('an account the command made logs in, changes its password and logs out', async ({ page, live }) => {
  const email = `${uniqueId('pw')}@example.com`;

  try {
    createConsoleUser(email, PASSWORD);

    await page.goto('/users/log-in');
    await submitLogin(page, { email, password: PASSWORD });
    // `/` lands on the Dashboard of the namespace last worked in, or on the list.
    await expect(page).toHaveURL(/\/namespaces(\/[^/?#]+)?$/);

    await page.goto('/users/settings');
    const form = page.locator('#update_password');
    await form.getByLabel('New password', { exact: true }).fill(NEXT_PASSWORD);
    await form.getByLabel('Confirm new password').fill(NEXT_PASSWORD);
    await form.getByRole('button', { name: 'Save Password' }).click();
    await expect(page.locator('body')).toContainText('Password updated successfully.');

    await live('/namespaces');
    await page.getByTestId('account-menu').click();
    await expect(page.getByTestId('account-identity')).toContainText(email);
    await page.getByTestId('log-out').click();
    await expect(page).toHaveURL(/\/users\/log-in$/);

    await page.goto('/');
    await expect(page).toHaveURL(/\/users\/log-in$/);

    // The old password is refused now, and the form says so.
    await submitLogin(page, { email, password: PASSWORD });
    await expect(page).toHaveURL(/\/users\/log-in$/);
    await expect(page.locator('body')).toContainText(/invalid/i);

    // The new password is the one that now opens the account.
    await submitLogin(page, { email, password: NEXT_PASSWORD });
    await expect(page).toHaveURL(/\/namespaces(\/[^/?#]+)?$/);
  } finally {
    deleteConsoleUser(email);
  }
});
