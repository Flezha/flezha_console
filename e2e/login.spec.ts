import { test, expect } from './fixtures';
import { submitLogin, workerUser } from './global-setup';

/**
 * The login form refusing a wrong password. A successful login through the
 * same form is what `global-setup.ts` does for every worker.
 */
test.use({ storageState: { cookies: [], origins: [] } });

test('an unauthenticated visit is sent to the form, which refuses a wrong password', async ({ page }) => {
  const { email } = workerUser(test.info().parallelIndex);

  await page.goto('/');
  await expect(page).toHaveURL(/\/users\/log-in$/);

  await submitLogin(page, { email, password: 'definitely_not_the_password' });

  await expect(page).toHaveURL(/\/users\/log-in$/);
  await expect(page.locator('body')).toContainText(/invalid/i);

  // Still refused when reaching for a protected screen afterwards.
  await page.goto('/');
  await expect(page).toHaveURL(/\/users\/log-in$/);
});
