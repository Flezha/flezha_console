import { chromium, expect, type FullConfig, type Page } from '@playwright/test';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';

/** Seeded by `priv/repo/seeds.exs` when the dev stack boots. */
export const DEV_EMAIL = 'dev@flezha.local';
export const DEV_PASSWORD = 'dev_password_123';

/**
 * Fills and submits the password login form.
 *
 * `email` is omitted when re-authenticating into sudo mode, where the field is
 * readonly and only the password is asked for.
 */
export async function submitLogin(
  page: Page,
  { email, password = DEV_PASSWORD }: { email?: string; password?: string } = {},
): Promise<void> {
  const form = page.locator('#login_form_password');

  if (email !== undefined) {
    await form.locator('input[name="user[email]"]').fill(email);
  }

  await form.locator('input[name="user[password]"]').fill(password);
  await form.getByRole('button', { name: /log in/i }).click();
}

/**
 * Logs in once and saves the session, so specs start authenticated instead of
 * re-running bcrypt and re-asserting login as a side effect of testing
 * something else. The form is driven in a real browser rather than POSTed
 * directly, because it carries a CSRF token.
 *
 * `login.spec.ts` still exercises the form itself, so this path is covered
 * rather than merely assumed to work.
 */
async function globalSetup(config: FullConfig) {
  const { baseURL, storageState } = config.projects[0].use;

  if (typeof storageState !== 'string') {
    throw new Error('globalSetup expects `storageState` to be a path in playwright.config.ts');
  }

  await mkdir(path.dirname(storageState), { recursive: true });

  const browser = await chromium.launch();
  const page = await browser.newPage({ baseURL });

  try {
    await page.goto('/users/log-in');

    await submitLogin(page, { email: DEV_EMAIL, password: DEV_PASSWORD });

    await page.waitForURL(`${baseURL}/`);
    await expect(page.locator('body')).toContainText('Dashboard');

    await page.context().storageState({ path: storageState });
  } finally {
    await browser.close();
  }
}

export default globalSetup;
