import { test, expect, expectHealthBadges, healthBadge } from './fixtures';

/**
 * Operative health on the namespace screen.
 *
 * A partition group with broken key-range coverage cannot be arranged against
 * a live controller — the UI cannot start partitioned members, and a healthy
 * dev stack has none. That fault is asserted in
 * `test/flezha_ui_web/live/namespace_live_test.exs`, which can produce it.
 * What lives here is the column itself, against real classifications.
 */
test.describe('Namespace operative health', () => {
  test.beforeEach(async ({ live }) => {
    await live('/namespaces/default');
  });

  test('every operative row carries a health the loop classified', async ({ page }) => {
    await expect(page.getByTestId('operatives-table')).toBeVisible();

    // Never blank, and never silently absent: an unobserved row reads
    // `unknown` rather than defaulting to healthy.
    await expectHealthBadges(page, 'operative-row-');
  });

  test('rows carry the node, factory and runner from the same registry read', async ({ page }) => {
    const row = page.getByTestId('operative-row-testnet_store_1');

    await expect(row).toContainText('store_input');
    await expect(row).toContainText('flezha@');
  });

  test('a suspended instance is distinguishable from a running one', async ({ page }) => {
    // The seeded chat workflow parks at its first iteration boundary, which the
    // Convergence Loop ranks in the health ladder.
    await expect(healthBadge(page, 'operative-row-testnet_chat')).toHaveAttribute(
      'data-health',
      'suspended',
    );

    // The stream operatives are not suspended — whatever else the loop
    // currently makes of them. Pinning one to `healthy` would be pinning a
    // value that legitimately moves as plugins attach and detach.
    await expect(healthBadge(page, 'operative-row-testnet_store_1')).not.toHaveAttribute(
      'data-health',
      'suspended',
    );
  });
});
