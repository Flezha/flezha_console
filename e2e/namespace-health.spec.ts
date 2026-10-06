import { test, expect, expectHealthBadges, healthBadge } from './fixtures';

/**
 * Relay health on the namespace screen.
 *
 * A partition group with broken key-range coverage cannot be arranged against
 * a live controller — the UI cannot start partitioned members, and a healthy
 * dev stack has none. That fault is asserted in
 * `test/flezha_ui_web/live/namespace_live_test.exs`, which can produce it.
 * What lives here is the column itself, against real classifications.
 */
test.describe('Namespace relay health', () => {
  test.beforeEach(async ({ live }) => {
    await live('/namespaces/default');
  });

  test('every relay row carries a health the loop classified', async ({ page }) => {
    await expect(page.getByTestId('relays-table')).toBeVisible();

    // Never blank, and never silently absent: an unobserved row reads
    // `unknown` rather than defaulting to healthy.
    await expectHealthBadges(page, 'relay-row-');
  });

  test('rows carry the node, factory and runner from the same registry read', async ({ page }) => {
    const row = page.getByTestId('relay-row-testnet_store_1');

    await expect(row).toContainText('store_input');
    await expect(row).toContainText('flezha@');
  });
});
