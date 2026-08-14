/**
 * E2E tests for attaching and detaching all available plugin providers.
 *
 * Discovers providers dynamically from the UI, then for each provider:
 *   1. Opens the attach modal and selects the provider
 *   2. Fills in the form with heuristic values (keeps server-generated plugin_id)
 *   3. Submits the form
 *   4. Verifies the binding row appears in the table
 *   5. Detaches the plugin and verifies binding row is removed
 */

interface ProviderInfo {
  id: string;
  label: string;
}

interface TestResult {
  provider: string;
  attach: 'pass' | 'fail';
  detach: 'pass' | 'fail' | 'skipped';
  error?: string;
}

function guessFieldValue(fieldName: string): string {
  const lower = fieldName.toLowerCase();
  // Boolean fields
  if (lower.includes('inverted') || lower.includes('enabled') || lower.includes('flag'))
    return 'false';
  // JSON object/array fields
  if (lower.includes('metadata')) return '{}';
  if (lower.includes('opts') || lower.includes('options')) return '[]';
  // URI/URL fields
  if (lower.includes('uri') || lower.includes('url')) return 'ws://localhost:9999/test';
  // Network fields
  if (lower.includes('hosts')) return 'localhost:9092';
  if (lower.includes('host')) return 'localhost';
  if (lower.includes('port')) return '9999';
  if (lower.includes('address')) return 'localhost:9999';
  // Path/file fields
  if (lower.includes('path')) return '/tmp/test';
  if (lower.includes('pattern') || lower.includes('regex')) return '.*';
  // Messaging fields
  if (lower.includes('topic')) return 'test-topic';
  if (lower.includes('channel')) return 'test-channel';
  if (lower.includes('queue')) return 'test-queue';
  // Numeric fields
  if (lower.includes('partition')) return '0';
  if (lower.includes('ack')) return '1';
  if (lower.includes('interval') || lower.includes('timeout')) return '5000';
  if (lower.includes('size') || lower.includes('count') || lower.includes('max')) return '100';
  // Name fields
  if (lower.includes('name')) return 'test_name';
  // Connection fields (leave empty — optional in most providers)
  if (lower === 'conn' || lower === 'post_connect') return 'test';
  return 'test_value_123';
}

/** Get all binding row plugin IDs currently in the table */
function getBindingPluginIds(): Cypress.Chainable<string[]> {
  return cy.document().then((doc) => {
    const rows = doc.querySelectorAll('[data-testid^="binding-row-"]');
    return Array.from(rows).map((el) => {
      const testid = el.getAttribute('data-testid') ?? '';
      return testid.replace('binding-row-', '');
    });
  });
}

/**
 * Attempts to attach a plugin for the given provider, then detach it.
 * Returns the result via callback (to work within Cypress command chain).
 */
function attachAndDetachProvider(
  provider: ProviderInfo,
  index: number,
  total: number,
  results: TestResult[],
): void {
  cy.task('log', `\n  [${index + 1}/${total}] Testing: ${provider.label} (${provider.id})`);

  // Record existing binding IDs before attach
  getBindingPluginIds().then((idsBefore) => {
    // Open modal
    cy.get('[data-testid="attach-plugin-btn"]').click();
    cy.get('[data-testid="provider-grid"]').should('be.visible');

    // Choose provider
    cy.get(`[data-testid="provider-btn-${provider.id}"]`).click();

    // Wait for configure form
    cy.get('[data-testid="input-plugin-id"]').should('be.visible');

    // Read the server-generated plugin_id
    cy.get('[data-testid="input-plugin-id"]')
      .invoke('val')
      .then((generatedId) => {
        const pluginId = generatedId as string;

        // Set position and trigger
        cy.get('[data-testid="input-position"]').clear().type(String(index));
        cy.get('[data-testid="input-trigger"]').select('on_input');

        // Fill in dynamic provider-specific fields
        cy.get('body').then(($body) => {
          const fields = $body.find('[data-testid^="input-field-"]');
          if (fields.length > 0) {
            fields.each((_i, el) => {
              const testid = el.getAttribute('data-testid') ?? '';
              const fieldName = testid.replace('input-field-', '');
              const value = guessFieldValue(fieldName);
              cy.wrap(el).clear().type(value);
            });
          }
        });

        // Submit
        cy.get('[data-testid="attach-submit-btn"]').click();

        // Wait for LiveView to process
        // eslint-disable-next-line cypress/no-unnecessary-waiting
        cy.wait(2000);

        // Check outcome
        cy.document().then((doc) => {
          const modalStillOpen = doc.querySelector('[data-testid="attach-modal"]') !== null;

          if (modalStillOpen) {
            // Attach returned an error — read it
            const errorEl = doc.querySelector('[data-testid="attach-error"]');
            const errorText = errorEl?.textContent?.trim() || 'unknown error';
            cy.task(
              'log',
              `         ATTACH FAILED: ${errorText.substring(0, 120)}`,
            );
            results.push({
              provider: provider.id,
              attach: 'fail',
              detach: 'skipped',
              error: errorText,
            });
            // Close modal to proceed
            cy.get('[data-testid="attach-cancel-btn"]').click({ force: true });
            cy.get('[data-testid="attach-modal"]').should('not.exist');
          } else {
            // Modal closed — check if a new binding row appeared
            getBindingPluginIds().then((idsAfter) => {
              const newIds = idsAfter.filter((id) => !idsBefore.includes(id));

              if (newIds.length > 0) {
                const newPluginId = newIds[0];
                cy.task('log', `         ATTACH OK (plugin_id: ${newPluginId})`);

                // --- DETACH ---
                cy.get(`[data-testid="detach-btn-${newPluginId}"]`).click();
                cy.get('[data-testid="detach-confirm-modal"]').should('be.visible');
                cy.get('[data-testid="detach-confirm-btn"]').click();

                // Verify row is gone
                cy.get(`[data-testid="binding-row-${newPluginId}"]`).should('not.exist');

                // Double-check: binding count should return to original
                getBindingPluginIds().then((idsAfterDetach) => {
                  const stillPresent = idsAfterDetach.includes(newPluginId);
                  if (stillPresent) {
                    cy.task('log', `         DETACH FAILED: row still present after detach`);
                    results.push({
                      provider: provider.id,
                      attach: 'pass',
                      detach: 'fail',
                      error: 'binding row still present after detach',
                    });
                  } else {
                    cy.task('log', `         DETACH OK`);
                    results.push({
                      provider: provider.id,
                      attach: 'pass',
                      detach: 'pass',
                    });
                  }
                });
              } else {
                // Modal closed but no new row
                cy.task(
                  'log',
                  `         ATTACH ACCEPTED but no new binding row (plugin may have crashed on init)`,
                );
                results.push({
                  provider: provider.id,
                  attach: 'fail',
                  detach: 'skipped',
                  error: 'modal closed but no new binding row appeared',
                });
              }
            });
          }
        });
      });
  });
}

describe('Plugin Attachment - All Providers', () => {
  beforeEach(() => {
    cy.login();
    cy.visit('/namespaces/default/operatives/testnet_store_1');
    cy.waitForLiveView();
  });

  it('discovers all available providers', () => {
    cy.get('[data-testid="attach-plugin-btn"]').click();
    cy.get('[data-testid="attach-modal"]').should('be.visible');
    cy.get('[data-testid="provider-grid"]').should('be.visible');

    cy.get('[data-testid^="provider-btn-"]').then(($buttons) => {
      const providers: ProviderInfo[] = [];
      $buttons.each((_i, el) => {
        const testid = el.getAttribute('data-testid') ?? '';
        const id = testid.replace('provider-btn-', '');
        const label = el.querySelector('p.text-sm')?.textContent?.trim() ?? id;
        providers.push({ id, label });
      });

      cy.task('log', `\n  Discovered ${providers.length} providers:`);
      providers.forEach((p) => cy.task('log', `    - ${p.label} (${p.id})`));

      expect(providers.length).to.be.greaterThan(0);
    });

    cy.get('button[phx-click="close_attach_modal"]').first().click();
    cy.get('[data-testid="attach-modal"]').should('not.exist');
  });

  it('attaches and detaches each provider', () => {
    const results: TestResult[] = [];

    // Discover providers
    cy.get('[data-testid="attach-plugin-btn"]').click();
    cy.get('[data-testid="provider-grid"]').should('be.visible');

    cy.get('[data-testid^="provider-btn-"]')
      .then(($buttons) => {
        const providers: ProviderInfo[] = [];
        $buttons.each((_i, el) => {
          const testid = el.getAttribute('data-testid') ?? '';
          const id = testid.replace('provider-btn-', '');
          const label = el.querySelector('p.text-sm')?.textContent?.trim() ?? id;
          providers.push({ id, label });
        });

        // Close discovery modal
        cy.get('button[phx-click="close_attach_modal"]').first().click();
        cy.get('[data-testid="attach-modal"]').should('not.exist');

        cy.task('log', `\n  Testing attach+detach for ${providers.length} providers:`);

        // Test each provider sequentially
        const chain = cy.wrap(null);
        providers.forEach((provider, index) => {
          chain.then(() => attachAndDetachProvider(provider, index, providers.length, results));
        });

        // Summary
        chain.then(() => {
          const passed = results.filter((r) => r.attach === 'pass' && r.detach === 'pass');
          const attachFailed = results.filter((r) => r.attach === 'fail');
          const detachFailed = results.filter(
            (r) => r.attach === 'pass' && r.detach === 'fail',
          );

          cy.task('log', '\n  ========== SUMMARY ==========');
          cy.task('log', `  Total providers: ${results.length}`);
          cy.task('log', `  Attach+Detach OK: ${passed.length}`);
          cy.task('log', `  Attach failed:    ${attachFailed.length}`);
          cy.task('log', `  Detach failed:    ${detachFailed.length}`);
          cy.task('log', '  ─────────────────────────────');
          results.forEach((r) => {
            const status = r.attach === 'pass' && r.detach === 'pass' ? 'PASS' : 'FAIL';
            const detail = r.error ? ` (${r.error.substring(0, 80)})` : '';
            cy.task('log', `  ${status} │ ${r.provider} │ attach=${r.attach} detach=${r.detach}${detail}`);
          });
          cy.task('log', '  ==============================\n');

          // Hard assertion: at least 1 provider must fully work
          expect(
            passed.length,
            `Expected at least 1 provider to fully pass. Results: ${JSON.stringify(results)}`,
          ).to.be.greaterThan(0);

          // Warn if any detach failed
          if (detachFailed.length > 0) {
            throw new Error(
              `Detach failed for: ${detachFailed.map((r) => r.provider).join(', ')}`,
            );
          }
        });
      });
  });

  it('attaches then immediately detaches (full round-trip)', () => {
    cy.task('log', '\n  Testing full attach→detach round-trip with flash verification...');

    // Attach a plugin so we have something to detach
    getBindingPluginIds().then((idsBefore) => {
      // Attach a stdout plugin (simplest — no external deps)
      cy.get('[data-testid="attach-plugin-btn"]').click();
      cy.get('[data-testid="provider-grid"]').should('be.visible');
      cy.get('[data-testid="provider-btn-operative_stdout"]').click();
      cy.get('[data-testid="input-plugin-id"]').should('be.visible');

      cy.get('[data-testid="input-plugin-id"]')
        .invoke('val')
        .then((pluginId) => {
          const pid = pluginId as string;
          cy.get('[data-testid="input-trigger"]').select('on_input');
          cy.get('[data-testid="attach-submit-btn"]').click();
          cy.get('[data-testid="attach-modal"]').should('not.exist');

          // Verify it was attached
          cy.get(`[data-testid="binding-row-${pid}"]`).should('exist');
          cy.task('log', `  Attached stdout plugin: ${pid}`);

          // Now detach it — this tests the direct operative fallback
          // because the PluginManager may or may not have it depending on state
          cy.task('log', `  Detaching plugin: ${pid}`);
          cy.get(`[data-testid="detach-btn-${pid}"]`).click();
          cy.get('[data-testid="detach-confirm-modal"]').should('be.visible');
          cy.get('[data-testid="detach-confirm-btn"]').click();

          // Verify removal
          cy.get(`[data-testid="binding-row-${pid}"]`).should('not.exist');

          // Verify no error flash
          cy.get('body').should('not.contain.text', 'Failed:');
          cy.get('body').should('contain.text', 'Plugin detached');

          // Verify count restored
          getBindingPluginIds().then((idsAfterDetach) => {
            expect(idsAfterDetach.length, 'Binding count should return to original').to.eq(
              idsBefore.length,
            );
            cy.task('log', '  Detach succeeded. Flash shows "Plugin detached". Count restored.');
          });
        });
    });
  });

  it('can detach any existing bindings shown on the page', () => {
    cy.task('log', '\n  Checking if existing bindings can be detached...');

    getBindingPluginIds().then((existingIds) => {
      if (existingIds.length === 0) {
        cy.task('log', '  No existing bindings to test. Skipping.');
        return;
      }

      cy.task('log', `  Found ${existingIds.length} existing binding(s): ${existingIds.join(', ')}`);

      // Try detaching the first existing binding
      const targetId = existingIds[0];
      cy.task('log', `  Attempting to detach: ${targetId}`);

      cy.get(`[data-testid="detach-btn-${targetId}"]`).click();
      cy.get('[data-testid="detach-confirm-modal"]').should('be.visible');
      cy.get('[data-testid="detach-confirm-btn"]').click();

      // Should succeed — row removed, no error flash
      cy.get(`[data-testid="binding-row-${targetId}"]`).should('not.exist');
      cy.get('body').should('not.contain.text', 'Failed:');

      cy.task('log', `  Successfully detached pre-existing binding: ${targetId}`);

      // Re-attach it so we don't leave the operative in a changed state
      // (only if it was a known provider type — skip if unknown)
    });
  });

  it('attaches and detaches the websocket provider on an extension it exports', () => {
    cy.task('log', '\n  Testing websocket plugin attach+detach explicitly...');

    getBindingPluginIds().then((idsBefore) => {
      cy.get('[data-testid="attach-plugin-btn"]').click();
      cy.get('[data-testid="provider-grid"]').should('be.visible');

      cy.get('[data-testid="provider-btn-operative_websocket"]').click();
      cy.get('[data-testid="input-plugin-id"]').should('be.visible');

      cy.get('[data-testid="input-plugin-id"]')
        .invoke('val')
        .then((pluginId) => {
          const pid = pluginId as string;
          cy.task('log', `  Plugin ID: ${pid}`);

          cy.get('[data-testid="input-field-uri"]').clear().type('ws://localhost:9999/test');

          // The websocket provider is a source: it connects when enabled and
          // exports `on_terminate` for teardown. Subscribing it to a transform
          // extension it does not export is refused by the controller.
          cy.get('[data-testid="input-trigger"]').select('on_terminate');

          cy.get('[data-testid="attach-submit-btn"]').click();

          cy.get('[data-testid="attach-modal"]').should('not.exist');

          getBindingPluginIds().then((idsAfter) => {
            const newIds = idsAfter.filter((id) => !idsBefore.includes(id));
            expect(newIds.length, 'Expected exactly 1 new binding row after websocket attach').to.eq(1);

            const newPluginId = newIds[0];
            cy.task('log', `  Websocket attached successfully as: ${newPluginId}`);

            cy.get(`[data-testid="binding-row-${newPluginId}"]`)
              .should('exist')
              .and('contain.text', 'Websocket')
              .and('contain.text', 'on_terminate');

            // --- DETACH ---
            cy.task('log', '  Detaching websocket plugin...');
            cy.get(`[data-testid="detach-btn-${newPluginId}"]`).click();
            cy.get('[data-testid="detach-confirm-modal"]').should('be.visible');
            cy.get('[data-testid="detach-confirm-btn"]').click();

            cy.get(`[data-testid="binding-row-${newPluginId}"]`).should('not.exist');

            getBindingPluginIds().then((idsAfterDetach) => {
              expect(idsAfterDetach.length, 'Binding count should return to original').to.eq(
                idsBefore.length,
              );
              cy.task('log', '  Websocket detached successfully. Binding count restored.\n');
            });
          });
        });
    });
  });

  it('refuses an extension the provider does not export', () => {
    // The extension table validates that the provider exports a callback for
    // every subscription. The websocket provider has no `on_input`, so this
    // must be reported rather than silently creating a plugin that never runs.
    getBindingPluginIds().then((idsBefore) => {
      cy.get('[data-testid="attach-plugin-btn"]').click();
      cy.get('[data-testid="provider-btn-operative_websocket"]').click();
      cy.get('[data-testid="input-plugin-id"]').should('be.visible');

      cy.get('[data-testid="input-field-uri"]').clear().type('ws://localhost:9999/test');
      cy.get('[data-testid="input-trigger"]').select('on_input');
      cy.get('[data-testid="attach-submit-btn"]').click();

      cy.get('[data-testid="attach-error"]').should('exist');
      cy.get('[data-testid="attach-modal"]').should('exist');

      cy.get('[data-testid="attach-cancel-btn"]').click();

      getBindingPluginIds().then((idsAfter) => {
        expect(idsAfter.length, 'A refused plugin must not appear as a binding').to.eq(
          idsBefore.length,
        );
      });
    });
  });
});
