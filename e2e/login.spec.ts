import { test, expect } from './fixtures';
import { DEV_EMAIL, DEV_PASSWORD, submitLogin } from './global-setup';

/**
 * The login form itself.
 *
 * Runs without the stored session — every other spec starts authenticated via
 * `global-setup.ts`, so without this the login path would be assumed to work
 * rather than tested.
 */
test.use({ storageState: { cookies: [], origins: [] } });

test.describe('Login', () => {
  test('an unauthenticated visit is redirected to the login form', async ({ page }) => {
    await page.goto('/');
    await expect(page).toHaveURL(/\/users\/log-in$/);
  });

  test('the seeded dev credentials land on a Home', async ({ page }) => {
    await page.goto('/users/log-in');

    await submitLogin(page, { email: DEV_EMAIL, password: DEV_PASSWORD });

    // `/` opens the Home of the namespace last worked in, or the list.
    await expect(page).toHaveURL(/\/namespaces(\/[^/?#]+)?$/);
    await expect(page.getByTestId('topbar')).toBeVisible();
  });

  test('a wrong password does not authenticate', async ({ page }) => {
    await page.goto('/users/log-in');

    await submitLogin(page, { email: DEV_EMAIL, password: 'definitely_not_the_password' });

    await expect(page).toHaveURL(/\/users\/log-in$/);
    await expect(page.locator('body')).toContainText(/invalid/i);

    // Still refused when reaching for a protected screen afterwards.
    await page.goto('/');
    await expect(page).toHaveURL(/\/users\/log-in$/);
  });
});
