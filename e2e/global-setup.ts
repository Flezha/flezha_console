import { chromium, expect, type FullConfig, type Page } from '@playwright/test';
import { execFile, execFileSync, spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { promisify } from 'node:util';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';

/** Seeded by `priv/repo/seeds.exs` when the dev stack boots. */
export const DEV_EMAIL = 'admin@flezha.com';
export const DEV_PASSWORD = 'admin';

const WORKER_PASSWORD = 'pw-worker-password';

/** The namespace whose existence says a run holds the stack. */
const STACK_LOCK = 'e2e-run-lock';

/** How long global setup lets the controller take to become ready. */
const READY_WITHIN_MS = 30_000;

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
 * The namespace worker `index` keeps its tokens and role bindings in, so no
 * other worker's rows reach its listings. Global setup makes it for this run,
 * whose id it hands the workers in `E2E_RUN_ID`: the run's start time in base
 * 36, always 8 characters.
 */
export function workerNamespace(index: number, run = process.env.E2E_RUN_ID): string {
  if (!run) throw new Error('E2E_RUN_ID is unset: global setup did not run');
  return `e2e-w${index}-${run}`;
}

/** The dev stack's console container, where the console's own mix tasks run. */
const CONSOLE_CONTAINER = 'fcon_web';

/**
 * The dev stack's tools container, which holds the cookie: every helper node
 * and CLI call runs there, reaching the controllers over distribution as `flz`
 * would on a controller's host. The console holds no cookie.
 */
const TOOLS_CONTAINER = 'fcon_tools';

/** A run id's form: `Date.now()` in base 36, 8 characters until 2059. */
const RUN_ID = /[0-9a-z]{8}/.source;
const WORKER_NAMESPACE = new RegExp(`^e2e-w\\d+-(${RUN_ID})$`);

/**
 * Runs `argv` inside `container` and answers its output. Throws with that
 * output when it fails.
 */
function inContainer(container: string, what: string, argv: string[]): string {
  try {
    return execFileSync('docker', ['exec', container, ...argv], { encoding: 'utf8', stdio: 'pipe' });
  } catch (error) {
    throw failed(what, error);
  }
}

/** `inContainer`, without holding the caller up while it runs. */
async function inContainerAsync(container: string, what: string, argv: string[]): Promise<string> {
  try {
    return (await promisify(execFile)('docker', ['exec', container, ...argv], { encoding: 'utf8' })).stdout;
  } catch (error) {
    throw failed(what, error);
  }
}

/** Runs `argv` inside `fcon_web`, the console's container. */
export const inConsole = (what: string, argv: string[]) => inContainer(CONSOLE_CONTAINER, what, argv);

/** Runs `argv` inside `fcon_tools`, where the helper nodes run. */
const inTools = (what: string, argv: string[]) => inContainer(TOOLS_CONTAINER, what, argv);

function failed(what: string, error: unknown): Error {
  const { stdout = '', stderr = '' } = error as { stdout?: string; stderr?: string };
  return new Error(`${what} failed:\n${stdout}${stderr}`);
}

/**
 * `elixir` running `args` as a node of the dev stack, so a script can reach
 * the console and the controller. Hidden, so it joins no node's mesh: each one
 * leaving would otherwise make `global` on every other node log, and churn the
 * controller and console. The cookie is the container's own `ERLANG_COOKIE`;
 * the node name and `args` reach `elixir` as positional parameters, never
 * through the shell's parsing. A run's nodes are named after it, `pw_<run>_…`,
 * so `liveRuns` can tell a run that is still going from one that died.
 */
export const elixirArgv = (args: string[]) => [
  'sh',
  '-c',
  'exec elixir --sname "$0" --hidden --cookie "$ERLANG_COOKIE" "$@"',
  uniqueId(`pw_${process.env.E2E_RUN_ID ?? 'cli'}`),
  ...args,
];

/**
 * The runs with a node up in `fcon_tools`, read from its epmd. Global setup
 * keeps its CLI node until its teardown, so a run is listed for as long as it
 * holds the stack, however long that is, and not once its process has gone.
 */
function liveRuns(): Set<string> {
  const names = inTools('listing the helper nodes', ['epmd', '-names']);
  return new Set([...names.matchAll(new RegExp(`^name pw_(${RUN_ID})_`, 'gm'))].map(([, run]) => run));
}

/** Runs `elixir` with `args` as a helper node inside `fcon_tools` and answers its output. */
export function devElixir(what: string, args: string[]): string {
  return inTools(what, elixirArgv(args));
}

/** Runs a script of `priv/dev` against the console's database, inside `fcon_web`. */
export function consoleScript(what: string, args: string[]): string {
  return inConsole(what, ['mix', 'run', '--no-start', ...args]);
}

type Waiting = { what: string; resolve: (out: string) => void; reject: (error: Error) => void };
type CliNode = { send: (what: string, door: string, requests: unknown[][]) => Promise<string>; close: () => void };
let cliNode: CliNode | undefined;

/**
 * Sends `requests` to `door` through this process's CLI node: one
 * `priv/dev/cli_call.exs --serve` inside `fcon_tools`, booted on the first call
 * and kept for the process's life, since a node boot costs over a CPU-second.
 * Answers what the door printed; rejects with the door's error.
 */
export function viaCliNode(what: string, door: string, requests: unknown[][]): Promise<string> {
  if (!cliNode) {
    // `docker exec -i`: the node serves until its stdin closes.
    const argv = elixirArgv(['/flezha_console/priv/dev/cli_call.exs', '--serve']);
    const child = spawn('docker', ['exec', '-i', TOOLS_CONTAINER, ...argv], { stdio: 'pipe' });
    const waiting: Waiting[] = [];
    let stderr = '';

    child.stderr.on('data', (chunk) => (stderr += chunk));
    // A write to a node that already exited fails here; its exit reports it.
    child.stdin.on('error', () => undefined);
    createInterface({ input: child.stdout }).on('line', (line) => {
      // A log line the node prints is not an answer; it is kept for a failure.
      const answer = parseAnswer(line);
      if (!answer) return void (stderr += `${line}\n`);

      const next = waiting.shift()!;
      if (answer.ok) return next.resolve(answer.out);
      // A door prints its refusal, `{"error": {"code": …}}`, on standard error.
      const printed = `${answer.out}${answer.error}`;
      const code = /"code":"([^"]+)"/.exec(printed)?.[1];
      next.reject(Object.assign(new Error(`${next.what} failed:\n${printed}`), { code }));
    });
    child.on('exit', (code) => {
      cliNode = undefined;
      for (const { what: failed, reject } of waiting.splice(0)) {
        reject(new Error(`${failed} failed: the CLI node exited with ${code}:\n${stderr}`));
      }
    });

    cliNode = {
      send: (what, name, args) =>
        new Promise((resolve, reject) => {
          waiting.push({ what, resolve, reject });
          child.stdin.write(`${JSON.stringify({ door: name, args })}\n`);
        }),
      close: () => child.stdin.end(),
    };
  }

  return cliNode.send(what, door, requests);
}

function parseAnswer(line: string): { ok: boolean; out: string; error?: string } | null {
  try {
    const answer = JSON.parse(line);
    return typeof answer?.ok === 'boolean' ? answer : null;
  } catch {
    return null;
  }
}

/** Whether `error` is a door's refusal with one of `codes`, such as `namespace.not_found`. */
export function refusedWith(error: unknown, ...codes: string[]): boolean {
  return codes.includes((error as { code?: string } | null)?.code ?? '');
}

/**
 * Runs the published operation `door` on the dev controller as `flz` sends it,
 * so the controller sees a CLI call, and answers its parsed JSON.
 */
export async function cliCall(door: string, args: unknown[]): Promise<unknown> {
  return JSON.parse(await viaCliNode(`cliCall ${door}`, door, [args]));
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

/** The dev stack's controllers: the one `default` runs on, then the second. */
export const CONTROLLERS = ['flezha@flezha_controller', 'flezha@flezha_controller_2'];

/** The machine a controller node runs on, as the console names it. */
export const machine = (node: string) => node.split('@')[1];

/**
 * The namespace only the second controller's runner serves, so a relay
 * started there from `SECOND_FACTORY` runs on the second controller.
 */
export const SECOND_NAMESPACE = 'second';
export const SECOND_FACTORY = 'store_input';

type BootStatus = {
  rows: {
    node: string;
    preconditions: { key: string; met: boolean }[];
    namespaces: { namespace: string; recovery_state: string }[];
  }[];
  unreachable: string[];
};

/** What keeps a controller from serving, or nothing once every one is ready. */
async function notReady(): Promise<string[]> {
  let status: BootStatus;
  try {
    status = (await cliCall('Controller.boot_status', [])) as BootStatus;
  } catch (error) {
    // Right after a restart the node is not up, or not answering, yet.
    return [`the controller does not answer: ${String(error).split('\n').slice(0, 3).join(' ')}`];
  }

  const answered = new Set(status.rows.map(({ node }) => node));

  // Each readiness verdict is its preconditions folded; each unmet one is named.
  return [
    ...CONTROLLERS.filter((node) => !answered.has(node)).map((node) => `${node} is not in the cluster`),
    ...status.rows.flatMap(({ node, preconditions, namespaces }) => [
      ...preconditions.filter(({ met }) => !met).map(({ key }) => `${node}: ${key} is unmet`),
      ...namespaces
        .filter(({ recovery_state }) => recovery_state !== 'normal')
        .map(({ namespace, recovery_state }) => `${node}: ${namespace} is ${recovery_state}`),
    ]),
    ...(await secondFactoryMissing()),
  ];
}

/** Names the second runner's factory while no runner of the second controller serves it. */
async function secondFactoryMissing(): Promise<string[]> {
  const { rows } = (await cliCall('Fleet.factories', [SECOND_NAMESPACE]).catch(() => ({ rows: [] }))) as {
    rows: { id: string; nodes: string[] }[];
  };
  const served = rows.some(({ id, nodes }) => id === SECOND_FACTORY && nodes.includes(CONTROLLERS[1]));
  return served ? [] : [`${CONTROLLERS[1]}'s runner does not serve ${SECOND_NAMESPACE}/${SECOND_FACTORY}`];
}

/**
 * Waits until both controllers are ready, every namespace's hub serves and the
 * second controller's runner serves its factory, so no test meets a
 * half-recovered cluster. A ready cluster answers at once; past
 * `READY_WITHIN_MS` this fails naming what is still not ready.
 */
async function awaitReady(): Promise<void> {
  const deadline = Date.now() + READY_WITHIN_MS;
  let blockers = await notReady();

  while (blockers.length > 0 && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 500));
    blockers = await notReady();
  }

  if (blockers.length > 0) {
    throw new Error(`The cluster was not ready within ${READY_WITHIN_MS / 1000} s: ${blockers.join('; ')}`);
  }
}

/** The run ids behind the worker namespaces on the stack, each with its namespaces. */
async function workerRuns(): Promise<Map<string, string[]>> {
  const runs = new Map<string, string[]>();
  const { rows } = (await cliCall('Relay.list_namespaces', [])) as { rows: { namespace: string }[] };
  for (const { namespace } of rows) {
    const run = WORKER_NAMESPACE.exec(namespace)?.[1];
    if (run) runs.set(run, [...(runs.get(run) ?? []), namespace]);
  }
  return runs;
}

const ago = (run: string) => `${Math.round((Date.now() - parseInt(run, 36)) / 1000)} s ago`;

/**
 * Takes the stack for run `run` by creating the lock namespace, which the
 * controller refuses to create twice, and answers the lock's `created_at`.
 *
 * While another run is still going the lock stops this one, naming that run;
 * a lock whose run has gone is taken over with a warning, as is any with
 * `E2E_TAKE_LOCK=1`. Nothing about the stack is changed before the lock is
 * held, so a refused run leaves the holder's users logged in.
 */
async function takeStack(run: string): Promise<number> {
  const create = async () => ((await cliCall('Namespace.create', [STACK_LOCK])) as { created_at: number }).created_at;

  // A takeover can race the holder giving the lock back, or another run taking
  // it over too; the second try settles either.
  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      return await create();
    } catch (error) {
      if (!refusedWith(error, 'namespace.already_exists')) throw error;
    }

    const holders = [...liveRuns()].filter((other) => other !== run);
    if (holders.length > 0 && process.env.E2E_TAKE_LOCK !== '1') {
      throw new Error(
        `Another browser run holds this stack (${holders.map((h) => `run ${h}, started ${ago(h)}`).join('; ')}). ` +
          `Wait for it to finish, or set E2E_TAKE_LOCK=1 if it is stuck.`,
      );
    }

    console.warn(`Taking the stack over from ${holders.length ? `run ${holders.join(', ')}` : 'a run that has gone'}.`);
    await deleteNamespaces([STACK_LOCK]);
  }
  return create();
}

/**
 * Deletes `namespaces`, each attempted even when one fails, and throws naming
 * the failures. One already gone counts as deleted.
 */
async function deleteNamespaces(namespaces: string[]): Promise<void> {
  const results = await Promise.allSettled(namespaces.map((ns) => cliCall('Namespace.delete', [ns])));
  const failures = results.flatMap((r, i) =>
    r.status === 'rejected' && !refusedWith(r.reason, 'namespace.not_found') ? [`${namespaces[i]}: ${r.reason}`] : [],
  );
  if (failures.length) throw new Error(`could not delete ${failures.join('\n')}`);
}

/**
 * Takes the stack for this run and readies it: waits for the controller, takes
 * the lock, clears worker namespaces left by runs that have gone and makes one
 * for each of this run's workers. Answers the teardown, which gives them back.
 */
async function holdStack(workers: number[]): Promise<() => Promise<void>> {
  const run = Date.now().toString(36);
  process.env.E2E_RUN_ID = run;

  // Safe at any point: it deletes only what this run made, and the lock only
  // once this run holds it.
  let lockedAt: number | undefined;
  const own = workers.map((index) => workerNamespace(index, run));
  const release = async () => {
    try {
      await deleteNamespaces(own);
    } finally {
      // A run that took the lock over from this one holds a lock of its own.
      const lock = (await cliCall('Namespace.get', [STACK_LOCK]).catch(() => null)) as { created_at: number } | null;
      if (lockedAt !== undefined && lock?.created_at === lockedAt) await deleteNamespaces([STACK_LOCK]);
      cliNode?.close();
    }
  };

  try {
    await awaitReady();
    lockedAt = await takeStack(run);

    const others = [...(await workerRuns())].filter(([other]) => other !== run);
    const live = others.length > 0 ? liveRuns() : new Set<string>();
    await deleteNamespaces(others.filter(([other]) => !live.has(other)).flatMap(([, namespaces]) => namespaces));
    await Promise.all(own.map((ns) => cliCall('Namespace.create', [ns])));
  } catch (error) {
    await giveBack(release);
    throw error;
  }

  return release;
}

/** Runs `release` after a failed setup, so that its own failure does not hide the setup's. */
async function giveBack(release?: () => Promise<void>): Promise<void> {
  await release?.().catch((error) => console.warn(`Could not give the stack back: ${error}`));
}

/**
 * Readies the stack and logs every worker in once, saving its session, so
 * specs start authenticated instead of re-running bcrypt and re-asserting login
 * as a side effect of testing something else. The form is driven in a real
 * browser rather than POSTed directly, because it carries a CSRF token.
 *
 * Before anything on the stack changes, the run waits for the controller and
 * takes the stack's lock (`holdStack`); the teardown this answers gives the
 * lock and the worker namespaces back, whether the tests passed or not.
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

  const workers = Array.from({ length: config.workers }, (_, index) => index);
  // Launched while the stack is readied, since neither waits on the other.
  const launched = chromium.launch();
  let release: (() => Promise<void>) | undefined;

  try {
    release = shared.size > 0 ? await holdStack(workers) : undefined;
    const browser = await launched;
    const logins = [...own].map(([state, baseURL]) =>
      logIn(browser, baseURL, state, { email: DEV_EMAIL, password: DEV_PASSWORD }),
    );

    if (shared.size > 0) {
      // The console decodes its controller's answers by these shapes, and the
      // fake controller ExUnit drives is checked against them, so a controller
      // that answers differently, or a channel that loses part of an answer,
      // fails here, before any spec. It only reads, so it runs while the
      // workers are made and logged in.
      logins.push(checkShapes());

      // Made afresh each run, so nothing a previous run left on a user reaches this one.
      consoleScript('creating the worker users', [
        'priv/dev/console_users.exs',
        'renew',
        WORKER_PASSWORD,
        ...workers.map((i) => workerUser(i).email),
      ]);

      for (const baseURL of shared) {
        for (const index of workers) logins.push(logIn(browser, baseURL, workerState(index), workerUser(index)));
      }
    }

    await Promise.all(logins);
  } catch (error) {
    await giveBack(release);
    throw error;
  } finally {
    await (await launched).close();
  }

  return release;
}

/**
 * Records the shapes of the controller's reads over distribution and checks
 * them against the committed file, then reads them again through the
 * console's own channel, decoded, while the scratch relays the reads need are
 * in place; they are removed whatever the outcome.
 */
async function checkShapes(): Promise<void> {
  const recorder = '/flezha_console/priv/dev/record_shapes.exs';

  try {
    await inContainerAsync(TOOLS_CONTAINER, "checking the controller's answer shapes", elixirArgv([recorder, '--check', '--keep']));
    await inContainerAsync(CONSOLE_CONTAINER, "checking the shapes through the console's channel", [
      'sh',
      '-c',
      'FLEZHA_CONSOLE_DEV_SETUP=false exec mix run priv/dev/record_shapes.exs --channel',
    ]);
  } finally {
    await inContainerAsync(TOOLS_CONTAINER, "removing the shape check's relays", elixirArgv([recorder, '--clean']));
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

    // `/` lands on the Dashboard of the namespace last worked in, or on the list.
    await page.waitForURL(/\/namespaces(\/[^/?#]+)?$/);
    await expect(page.getByTestId('topbar')).toBeVisible();

    await context.storageState({ path: storageState });
  } finally {
    await context.close();
  }
}

export default globalSetup;
