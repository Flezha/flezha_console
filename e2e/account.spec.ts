import { test, expect, createConsoleUser, deleteConsoleUser, uniqueId, type Page } from './fixtures';
import { submitLogin } from './global-setup';

/**
 * Accounts made by the operator's command, logging in and out, and the account
 * settings forms, as a user each test makes for itself.
 *
 * Nothing here runs as the seeded dev user: changing its password or ending
 * its session would log every later spec out. The dev stack's mail goes to the
 * Swoosh mailbox at `/dev/mailbox`. Each user a test makes is deleted again
 * when it finishes.
 */
test.use({ storageState: { cookies: [], origins: [] } });

const PASSWORD = 'a long enough password';

/** Makes a fresh user with `mix flezha_ui.create_user` and logs it in. */
async function createAndLogIn(page: Page): Promise<string> {
  const email = `${uniqueId('pw')}@example.com`;
  createConsoleUser(email, PASSWORD);

  await page.goto('/users/log-in');
  await submitLogin(page, { email, password: PASSWORD });
  // `/` lands on the Home of the namespace last worked in, or on the list.
  await expect(page).toHaveURL(/\/namespaces(\/[^/?#]+)?$/);
  // Joined before the test moves on, so the page is not left mid-connect.
  await expect(page.locator('[data-phx-main]')).not.toHaveClass(/phx-loading/);
  return email;
}

test.describe('Accounts', () => {
  test('there is no registration page, and the login says who makes accounts', async ({
    page,
    pageHealth,
  }) => {
    pageHealth.allow(/\/users\/register/, 'the test asks for the page to prove it is not there');
    expect((await page.goto('/users/register'))?.status()).toBe(404);

    await page.goto('/users/log-in');
    await expect(page.getByTestId('page-sentence')).toContainText('created by an operator');
    await expect(page.locator('a[href="/users/register"]')).toHaveCount(0);
  });

  test('an account the command made logs in with its password, and logging out ends the session', async ({
    page,
  }) => {
    let email = '';

    try {
      email = await createAndLogIn(page);

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
    email = await createAndLogIn(page);
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
