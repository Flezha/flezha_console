import { test, expect } from '@playwright/test';
import { DEV_EMAIL, DEV_PASSWORD } from './global-setup';

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

  test('the seeded dev credentials land on the dashboard', async ({ page }) => {
    await page.goto('/users/log-in');

    const form = page.locator('#login_form_password');
    await form.locator('input[name="user[email]"]').fill(DEV_EMAIL);
    await form.locator('input[name="user[password]"]').fill(DEV_PASSWORD);
    await form.getByRole('button', { name: /log in/i }).click();

    await expect(page).toHaveURL(/localhost:4000\/$/);
    await expect(page.locator('body')).toContainText('Dashboard');
  });

  test('a wrong password does not authenticate', async ({ page }) => {
    await page.goto('/users/log-in');

    const form = page.locator('#login_form_password');
    await form.locator('input[name="user[email]"]').fill(DEV_EMAIL);
    await form.locator('input[name="user[password]"]').fill('definitely_not_the_password');
    await form.getByRole('button', { name: /log in/i }).click();

    await expect(page).toHaveURL(/\/users\/log-in$/);
    await expect(page.locator('body')).toContainText(/invalid/i);

    // Still refused when reaching for a protected screen afterwards.
    await page.goto('/');
    await expect(page).toHaveURL(/\/users\/log-in$/);
  });
});
