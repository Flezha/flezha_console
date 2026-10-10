import { test, expect, deleteConsoleUser, uniqueId, type Page } from './fixtures';
import { DEV_EMAIL } from './global-setup';

/**
 * Registration, logging in by the emailed link, logging out, and the account
 * settings forms, as a user each test registers for itself.
 *
 * Nothing here runs as the seeded dev user: changing its password or ending
 * its session would log every later spec out. The dev stack's mail goes to the
 * Swoosh mailbox at `/dev/mailbox`, which is where the login link is read
 * from. Each user a test registers is deleted again when it finishes.
 */
test.use({ storageState: { cookies: [], origins: [] } });

/** The newest login link the dev mailbox holds for `email`. */
async function loginLink(page: Page, email: string): Promise<string> {
  let link = '';
  await expect
    .poll(
      async () => {
        const { data } = await (await page.request.get('/dev/mailbox/json')).json();
        const mail = (data as { to: string[]; text_body: string }[]).find((m) =>
          m.to.includes(email),
        );
        link = mail?.text_body.match(/https?:\/\/\S+\/users\/log-in\/\S+/)?.[0] ?? '';
        return link;
      },
      { message: `no login mail for ${email}` },
    )
    .not.toBe('');
  return new URL(link).pathname;
}

/** Registers a fresh user and logs it in through its emailed link. */
async function registerAndLogIn(page: Page): Promise<string> {
  const email = `${uniqueId('pw')}@example.com`;
  await page.goto('/users/register');
  await page.getByLabel('Email').fill(email);
  await page.getByRole('button', { name: 'Create account' }).click();
  await expect(page).toHaveURL(/\/users\/log-in$/);
  await expect(page.locator('body')).toContainText(email);

  await page.goto(await loginLink(page, email));
  await page.getByRole('button', { name: 'Confirm and stay logged in' }).click();
  await expect(page).toHaveURL(/localhost:4000\/$/);
  // Joined before the test moves on, so the page is not left mid-connect.
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-loading/);
  return email;
}

test.describe('Registration', () => {
  test('a taken email is refused and no account is made', async ({ page }) => {
    await page.goto('/users/register');
    await page.getByLabel('Email').fill(DEV_EMAIL);
    await page.getByRole('button', { name: 'Create account' }).click();

    await expect(page).toHaveURL(/\/users\/register$/);
    await expect(page.locator('body')).toContainText('has already been taken');
  });

  test('a new account logs in by its emailed link, and logging out ends the session', async ({
    page,
  }) => {
    let email = '';

    try {
      email = await registerAndLogIn(page);

      await page.getByTestId('account-menu').click();
      await expect(page.getByTestId('account-identity')).toContainText(email);
      await page.getByTestId('log-out').click();
      await expect(page).toHaveURL(/\/users\/log-in$/);

      await page.goto('/');
      await expect(page).toHaveURL(/\/users\/log-in$/);
    } finally {
      if (email) deleteConsoleUser(email);
    }
  });
});

test.describe('Account settings', () => {
  let email = '';

  test.afterEach(() => {
    if (email) deleteConsoleUser(email);
  });

  test.beforeEach(async ({ page }) => {
    email = await registerAndLogIn(page);
    await page.goto('/users/settings');
    await expect(page.getByTestId('flezha-token-settings')).toBeVisible();
  });

  test('an email change to the same address is refused, and a new one mailed for confirmation', async ({
    page,
  }) => {
    const form = () => page.locator('#update_email');
    const current = await form().getByLabel('Email').inputValue();

    await form().getByLabel('Email').fill(current);
    await form().getByRole('button', { name: 'Change Email' }).click();
    await expect(form()).toContainText('did not change');

    const next = `${uniqueId('pw_next')}@example.com`;
    await form().getByLabel('Email').fill(next);
    await form().getByRole('button', { name: 'Change Email' }).click();
    await expect(page.locator('body')).toContainText(
      'A link to confirm your email change has been sent',
    );
  });

  test('a password change is refused when the two do not match, and saved when they do', async ({
    page,
  }) => {
    const form = () => page.locator('#update_password');

    await form().getByLabel('New password', { exact: true }).fill('a long enough password');
    await form().getByLabel('Confirm new password').fill('a different password');
    await form().getByRole('button', { name: 'Save Password' }).click();
    await expect(form()).toContainText('does not match password');

    await form().getByLabel('New password', { exact: true }).fill('a long enough password');
    await form().getByLabel('Confirm new password').fill('a long enough password');
    await form().getByRole('button', { name: 'Save Password' }).click();
    await expect(page.locator('body')).toContainText('Password updated successfully.');
  });

  test('a token that does not verify is said so in words, and no bootstrap claim is offered', async ({
    page,
  }) => {
    await page.locator('#flezha_token_token').fill('flzt_not_a_token_the_controller_issued');
    await page.locator('#update_flezha_token button').click();
    await expect(page.locator('body')).toContainText('did not verify: ');
    await expect(page.locator('body')).toContainText('(authz.token_');
    await expect(page.locator('body')).not.toContainText('%Flezha.Error');

    // The dev stack's controller is claimed, so the claim is not offered.
    await expect(page.getByTestId('bootstrap-claim')).toHaveCount(0);
  });
});
