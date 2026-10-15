import { chromium, expect, type FullConfig, type Page } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';

/** Seeded by `priv/repo/seeds.exs` when the dev stack boots. */
export const DEV_EMAIL = 'admin@flezha.com';
export const DEV_PASSWORD = 'admin';

const WORKER_PASSWORD = 'pw-worker-password';

/** Unique per test, so a leftover from a failed run cannot collide. */
export function uniqueId(prefix: string): string {
  const ts = Date.now().toString(36).slice(-4);
  const rand = Math.random().toString(36).slice(2, 5);
  return `${prefix}_${ts}_${rand}`;
}

/**
 * The console user worker `index` logs in as. Per-user state — a stored flezha
 * token, the namespace last worked in — stays inside one worker this way.
 */
export function workerUser(index: number): { email: string; password: string } {
  return { email: `pw-worker-${index}@flezha.test`, password: WORKER_PASSWORD };
}

/** Where worker `index`'s session is stored. */
export function workerState(index: number): string {
  return `e2e/.auth/worker-${index}.json`;
}

/**
 * Runs `elixir` inside `fui_web` as a distributed node of the dev stack, so a
 * script can reach the console and the controller, and answers its output.
 * Throws with the script's output when it fails.
 */
export function devElixir(what: string, args: string[]): string {
  const argv = ['exec', 'fui_web', 'elixir', '--sname', uniqueId('pw_cli'), '--cookie', 'flezha_dev_cookie', ...args];

  try {
    return execFileSync('docker', argv, { encoding: 'utf8', stdio: 'pipe' });
  } catch (error) {
    const { stdout = '', stderr = '' } = error as { stdout?: string; stderr?: string };
    throw new Error(`${what} failed:\n${stdout}${stderr}`);
  }
}

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
 * Logs every worker in once and saves its session, so specs start
 * authenticated instead of re-running bcrypt and re-asserting login as a side
 * effect of testing something else. The form is driven in a real browser
 * rather than POSTed directly, because it carries a CSRF token.
 *
 * A project that names its own `storageState` is a stack of its own — the
 * market stack — and logs in once as that stack's seeded user.
 *
 * `account.spec.ts` still exercises the form itself, so this path is covered
 * rather than merely assumed to work.
 */
async function globalSetup(config: FullConfig) {
  const own = new Map<string, string | undefined>();
  const shared = new Set<string | undefined>();

  for (const { use } of config.projects) {
    if (typeof use.storageState === 'string') {
      const known = own.get(use.storageState);
      if (known !== undefined && known !== use.baseURL) {
        throw new Error(`${use.storageState} would hold the session of both ${known} and ${use.baseURL}`);
      }
      own.set(use.storageState, use.baseURL);
    } else {
      shared.add(use.baseURL);
    }
  }

  const browser = await chromium.launch();

  try {
    const logins = [...own].map(([state, baseURL]) =>
      logIn(browser, baseURL, state, { email: DEV_EMAIL, password: DEV_PASSWORD }),
    );

    if (shared.size > 0) {
      // The fake controller ExUnit drives is checked against these shapes, so
      // a controller that answers differently fails here, before any spec.
      devElixir("checking the controller's answer shapes", ['/flezha_ui/priv/dev/record_shapes.exs', '--check']);

      const workers = Array.from({ length: config.workers }, (_, index) => index);
      // Made afresh each run, so nothing a previous run left on a user reaches this one.
      devElixir('creating the worker users', [
        '/flezha_ui/priv/dev/console_users.exs',
        'renew',
        WORKER_PASSWORD,
        ...workers.map((i) => workerUser(i).email),
      ]);

      for (const baseURL of shared) {
        for (const index of workers) logins.push(logIn(browser, baseURL, workerState(index), workerUser(index)));
      }
    }

    await Promise.all(logins);
  } finally {
    await browser.close();
  }
}

async function logIn(
  browser: Awaited<ReturnType<typeof chromium.launch>>,
  baseURL: string | undefined,
  storageState: string,
  user: { email: string; password: string },
) {
  await mkdir(path.dirname(storageState), { recursive: true });
  const context = await browser.newContext({ baseURL });
  const page = await context.newPage();

  try {
    await page.goto('/users/log-in');

    await submitLogin(page, user);

    // `/` lands on the Home of the namespace last worked in, or on the list.
    await page.waitForURL(/\/namespaces(\/[^/?#]+)?$/);
    await expect(page.getByTestId('topbar')).toBeVisible();

    await context.storageState({ path: storageState });
  } finally {
    await context.close();
  }
}

export default globalSetup;
