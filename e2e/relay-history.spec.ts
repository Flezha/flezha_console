import { test, expect, sendRecords, startRelayCli, stopRelayCli, uniqueId, SEEDED_FACTORY } from './fixtures';

/**
 * The relay history as the console reads it: a run's started and ended
 * records on the Logs screen, the finished relay page they lead to, and a
 * relay's Recent activity strip kept live by the history's tail.
 *
 * Each test starts its own relay under a run-unique id and filters by it, so
 * other workers' runs never reach its assertions. The dev controllers keep no
 * finished relay's state, as core's default does.
 */

// Runs once: its first message on `in` ends the run, without a stop.
const RUN_ONCE = 'echo_steps';

const historyOf = (id: string) => `/logs/relay_history?namespace=default&relay=${id}`;

test.describe('Relay history', () => {
  test("a run-once relay's start and end read as sentences, and its link opens its finished page", async ({
    page,
    live,
  }) => {
    const id = uniqueId('pw_hist');
    try {
      await startRelayCli(id, RUN_ONCE);
      // Taken once the relay is up; a send before then is refused.
      await expect(async () => sendRecords(id, ['once'], 'in')).toPass();

      const sentences = page.getByTestId('log-record-sentence');
      // The run ends on its own time: read again until its end is recorded.
      await expect(async () => {
        await live(historyOf(id));
        await expect(sentences.filter({ hasText: `${id} finished` })).toHaveCount(1, { timeout: 1_000 });
      }).toPass();

      await expect(page.getByTestId('logs-tab-relay_history')).toHaveAttribute('aria-current', 'page');
      await expect(page.getByTestId('logs-filter-relay')).toHaveValue(id);
      await expect(sentences.filter({ hasText: `${id} started from ${RUN_ONCE}` })).toHaveCount(1);
      // Newest first: the end above the start.
      await expect(sentences.first()).toContainText(`${id} finished`);

      await sentences.first().getByRole('link', { name: id, exact: true }).click();
      await expect(page).toHaveURL(new RegExp(`/namespaces/default/relays/${id}$`));
      await expect(page.getByTestId('finished-run')).toBeVisible();
      await expect(page.getByTestId('finished-state')).toContainText('state was not kept');
      await expect(page.getByTestId('stop-relay-btn')).toHaveCount(0);
    } finally {
      await stopRelayCli(id);
    }
  });

  test("a relay's recent activity gains its end as it stops, without a reload", async ({ page, live }) => {
    const id = uniqueId('pw_activity');
    try {
      await startRelayCli(id, SEEDED_FACTORY.flow);
      await live(`/namespaces/default/relays/${id}`);

      const strip = page.getByTestId('recent-activity-sentence');
      await expect(strip.filter({ hasText: `${id} started` })).toHaveCount(1);
      await expect(page.getByTestId('recent-activity-link')).toHaveAttribute(
        'href',
        new RegExp(`/logs/relay_history\\?.*relay=${id}`),
      );

      // A reload would drop this marker: the end must arrive by the tail.
      await page.evaluate(() => ((window as any).__activity = true));
      await stopRelayCli(id);

      await expect(strip.filter({ hasText: `${id} finished` })).toHaveCount(1);
      await expect(strip.first()).toContainText(`${id} finished`);
      expect(await page.evaluate(() => (window as any).__activity)).toBe(true);
    } finally {
      await stopRelayCli(id);
    }
  });
});
