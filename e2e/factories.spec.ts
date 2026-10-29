import { test, expect, growListing, openStart, sendRecords, startRelayCli, stopRelayCli, uniqueId, SEEDED_FACTORY } from './fixtures';

/**
 * A factory's page, reached as an operator reaches it, against the dev
 * runner's own factories.
 *
 * The dev runners announce their factories in `default` only, so the specs
 * read it there. `chat_loop_steps` is the seeded steps factory; its loop runs
 * one pass per message and never ends by itself, so the last-runs spec ends
 * a run of `echo_steps`, which ends after its first message.
 */

const STEPS = SEEDED_FACTORY.steps;
const RUN_ONCE = 'echo_steps';
const factoryPage = (id: string) => `/namespaces/default/factories/${id}`;

test.describe('Factories', () => {
  test("the rail leads to a steps factory's page, which says how it runs and draws it still", async ({
    page,
    live,
  }) => {
    await live('/namespaces/default');
    const rail = page.locator('.flz-sidebar-nav');
    await rail.locator('a.flz-sidebar-link[href="/namespaces/default/factories"]').click();
    await expect(page).toHaveURL(/\/namespaces\/default\/factories$/);
    await expect(rail.locator('a[aria-current="page"]')).toHaveText('Factories');

    // The runner's catalogue is longer than a page.
    const link = page.getByTestId(`factory-link-${STEPS}`);
    await growListing(page, 'factories-default', link);
    await link.click();
    await expect(page).toHaveURL(new RegExp(`${factoryPage(STEPS)}$`));
    const crumbs = page.getByTestId('breadcrumb');
    await expect(crumbs.getByRole('link', { name: 'Factories' })).toHaveAttribute('href', '/namespaces/default/factories');
    await expect(crumbs.locator('[aria-current="page"]')).toHaveText(STEPS);
    await expect(rail.locator('a[aria-current="page"]')).toHaveText('Factories');

    await expect(page.getByTestId('factory-run')).toContainText('works through its steps');
    await expect(page.locator('#topology-svg [data-node^="tasklet-"]')).not.toHaveCount(0);
    await expect(page.getByTestId('topology-state')).toHaveCount(0);

    // The viewer's controls are the relay graph's own.
    for (const dir of ['TB', 'LR'] as const) {
      await page.getByTestId(`topology-dir-${dir}`).click();
      await expect(page.getByTestId('topology-canvas')).toHaveAttribute('data-direction', dir);
    }
    await page.getByTestId('topology-fit').click();
    const svg = page.locator('#topology-svg');
    const fitted = await svg.getAttribute('viewBox');
    await page.getByTestId('topology-zoom-in').click();
    await expect.poll(() => svg.getAttribute('viewBox')).not.toBe(fitted);
    await page.getByTestId('topology-fit').click();
    await expect(svg).toHaveAttribute('viewBox', fitted!);
    await page.getByTestId('topology-dir-auto').click();
  });

  test("a run that ended is among the factory's last runs, linked to its history", async ({ page, live }) => {
    const id = uniqueId('pw_fac');
    try {
      await startRelayCli(id, RUN_ONCE);
      // Taken once the relay is up; a send before then is refused.
      await expect(async () => sendRecords(id, ['once'], 'in')).toPass();

      const line = page.getByTestId(`factory-run-${id}`);
      // The run ends on its own time: read again until its end is listed.
      await expect(async () => {
        await live(factoryPage(RUN_ONCE));
        await expect(line).toContainText(`${id} finished`, { timeout: 1_000 });
      }).toPass();

      await page.getByTestId(`factory-run-link-${id}`).click();
      await expect(page).toHaveURL(new RegExp(`/logs/relay_history\\?.*relay=${id}`));
      await expect(page.getByTestId('logs-filter-relay')).toHaveValue(id);
    } finally {
      await stopRelayCli(id);
    }
  });

  test("the launcher's chosen factory offers its page", async ({ page, live }) => {
    await live('/namespaces/default/relays');
    await openStart(page);
    await page.getByTestId(`factory-choice-${STEPS}`).click();
    await page.getByTestId('factory-how-it-works').click();

    await expect(page).toHaveURL(new RegExp(`${factoryPage(STEPS)}$`));
    await expect(page.getByTestId('page-title')).toHaveText(STEPS);
  });
});
