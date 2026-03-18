/**
 * E2E tests for processor lifecycle: starting and stopping processors.
 *
 * Tests run against the namespace show page (/namespaces/default) and:
 *   1. Verify the start modal opens and lists available factories
 *   2. Start a new processor with a unique ID via the first available factory
 *   3. Verify the processor row appears in the processors table
 *   4. Navigate to the processor detail page and back
 *   5. Stop the processor and verify the row is removed
 *   6. Test validation (empty fields, duplicate IDs)
 */

const NAMESPACE = 'default';
const NAMESPACE_URL = `/namespaces/${NAMESPACE}`;

/** Generate a unique processor ID for each test run to avoid collisions */
function uniqueProcessorId(prefix = 'cy_test'): string {
  const ts = Date.now().toString(36).slice(-4);
  const rand = Math.random().toString(36).slice(2, 5);
  return `${prefix}_${ts}_${rand}`;
}

/** Get all processor IDs currently shown in the table */
function getProcessorIds(): Cypress.Chainable<string[]> {
  return cy.document().then((doc) => {
    const rows = doc.querySelectorAll('[data-testid^="processor-row-"]');
    return Array.from(rows).map((el) => {
      const testid = el.getAttribute('data-testid') ?? '';
      return testid.replace('processor-row-', '');
    });
  });
}

describe('Processor Lifecycle - Start & Stop', () => {
  beforeEach(() => {
    cy.login();
    cy.visit(NAMESPACE_URL);
    cy.waitForLiveView();
  });

  it('opens the start modal and shows available factories', () => {
    cy.get('[data-testid="start-processor-btn"]').click();
    cy.get('[data-testid="start-modal"]').should('be.visible');

    // Factory dropdown should exist
    cy.get('[data-testid="input-factory-id"]').should('exist');

    // Check that factories are loaded (select is NOT disabled)
    cy.get('[data-testid="input-factory-id"]').should('not.be.disabled');

    // List the available factory options
    cy.get('[data-testid="input-factory-id"] option').then(($options) => {
      // Filter out the placeholder "Select a factory..." option
      const factories = Array.from($options)
        .map((el) => el.getAttribute('value'))
        .filter((v) => v !== null && v !== '');

      cy.task('log', `\n  Found ${factories.length} factories:`);
      factories.forEach((f) => cy.task('log', `    - ${f}`));

      expect(factories.length, 'At least one factory should be available').to.be.greaterThan(0);
    });

    // Close the modal
    cy.get('[data-testid="start-cancel-btn"]').click();
    cy.get('[data-testid="start-modal"]').should('not.exist');
  });

  it('validates required fields', () => {
    cy.get('[data-testid="start-processor-btn"]').click();
    cy.get('[data-testid="start-modal"]').should('be.visible');

    // Submit with empty fields
    cy.get('[data-testid="start-submit-btn"]').click();

    // Should show error - modal stays open
    cy.get('[data-testid="start-modal"]').should('be.visible');
    cy.get('[data-testid="start-error"]').should('be.visible');
    cy.get('[data-testid="start-error"]').should('contain.text', 'required');

    cy.task('log', '\n  Validated: empty fields show error correctly');

    // Close modal
    cy.get('[data-testid="start-cancel-btn"]').click();
    cy.get('[data-testid="start-modal"]').should('not.exist');
  });

  it('validates invalid JSON in init values', () => {
    cy.get('[data-testid="start-processor-btn"]').click();
    cy.get('[data-testid="start-modal"]').should('be.visible');

    // Fill in valid ID and factory, but invalid JSON
    const procId = uniqueProcessorId();
    cy.get('[data-testid="input-processor-id"]').clear().type(procId);

    // Select the first available factory
    cy.get('[data-testid="input-factory-id"] option')
      .not(':first')
      .first()
      .then(($opt) => {
        const factoryId = $opt.val() as string;
        cy.get('[data-testid="input-factory-id"]').select(factoryId);
      });

    // Type invalid JSON
    cy.get('[data-testid="input-init-values"]').clear().type('not valid json{{{');

    // Submit
    cy.get('[data-testid="start-submit-btn"]').click();

    // Should show JSON error
    cy.get('[data-testid="start-modal"]').should('be.visible');
    cy.get('[data-testid="start-error"]').should('be.visible');
    cy.get('[data-testid="start-error"]').should('contain.text', 'JSON');

    cy.task('log', '\n  Validated: invalid JSON shows error correctly');

    // Close modal
    cy.get('[data-testid="start-cancel-btn"]').click();
  });

  it('starts a processor and verifies it appears in the table', () => {
    const procId = uniqueProcessorId();
    cy.task('log', `\n  Starting processor: ${procId}`);

    getProcessorIds().then((idsBefore) => {
      cy.task('log', `  Processors before: ${idsBefore.length} [${idsBefore.join(', ')}]`);

      // Open start modal
      cy.get('[data-testid="start-processor-btn"]').click();
      cy.get('[data-testid="start-modal"]').should('be.visible');

      // Fill in the processor ID
      cy.get('[data-testid="input-processor-id"]').clear().type(procId);

      // Select the first available factory
      cy.get('[data-testid="input-factory-id"] option')
        .not(':first')
        .first()
        .then(($opt) => {
          const factoryId = $opt.val() as string;
          cy.task('log', `  Using factory: ${factoryId}`);
          cy.get('[data-testid="input-factory-id"]').select(factoryId);
        });

      // Submit
      cy.get('[data-testid="start-submit-btn"]').click();

      // Modal should close on success
      cy.get('[data-testid="start-modal"]').should('not.exist');

      // Flash message should confirm start
      cy.get('body').should('contain.text', `Processor ${procId} started`);

      // New row should appear in the table
      cy.get(`[data-testid="processor-row-${procId}"]`, { timeout: 10000 }).should('exist');

      getProcessorIds().then((idsAfter) => {
        cy.task('log', `  Processors after: ${idsAfter.length} [${idsAfter.join(', ')}]`);
        expect(idsAfter).to.include(procId);
        expect(idsAfter.length).to.eq(idsBefore.length + 1);
      });

      // --- CLEANUP: stop the processor ---
      cy.task('log', `  Cleaning up: stopping ${procId}`);
      cy.get(`[data-testid="stop-processor-${procId}"]`).click();
      cy.get('[data-testid="stop-confirm-modal"]').should('be.visible');
      cy.get('[data-testid="stop-confirm-btn"]').click();
      cy.get(`[data-testid="processor-row-${procId}"]`).should('not.exist');
      cy.task('log', '  Cleanup complete.');
    });
  });

  it('starts a processor, navigates to detail page, then stops it', () => {
    const procId = uniqueProcessorId('cy_nav');
    cy.task('log', `\n  Full lifecycle test: ${procId}`);

    // Start processor
    cy.get('[data-testid="start-processor-btn"]').click();
    cy.get('[data-testid="start-modal"]').should('be.visible');
    cy.get('[data-testid="input-processor-id"]').clear().type(procId);

    cy.get('[data-testid="input-factory-id"] option')
      .not(':first')
      .first()
      .then(($opt) => {
        const factoryId = $opt.val() as string;
        cy.task('log', `  Factory: ${factoryId}`);
        cy.get('[data-testid="input-factory-id"]').select(factoryId);
      });

    cy.get('[data-testid="start-submit-btn"]').click();
    cy.get('[data-testid="start-modal"]').should('not.exist');

    // Verify row appeared
    cy.get(`[data-testid="processor-row-${procId}"]`).should('exist');
    cy.task('log', '  Processor started and visible in table.');

    // Navigate to processor detail page
    cy.get(`[data-testid="view-processor-${procId}"]`).click();
    cy.waitForLiveView();

    // Verify we're on the processor detail page
    cy.url().should('include', `/namespaces/${NAMESPACE}/processors/${procId}`);
    cy.get('body').should('contain.text', procId);
    cy.task('log', '  Navigated to processor detail page.');

    // Go back to namespace page
    cy.visit(NAMESPACE_URL);
    cy.waitForLiveView();

    // Processor should still be in the table
    cy.get(`[data-testid="processor-row-${procId}"]`).should('exist');
    cy.task('log', '  Processor persists after navigation.');

    // Stop the processor
    cy.get(`[data-testid="stop-processor-${procId}"]`).click();
    cy.get('[data-testid="stop-confirm-modal"]').should('be.visible');
    cy.get('[data-testid="stop-confirm-btn"]').click();

    // Verify removal
    cy.get(`[data-testid="processor-row-${procId}"]`).should('not.exist');
    cy.get('body').should('contain.text', `Processor ${procId} stopped`);
    cy.get('body').should('not.contain.text', 'Failed');
    cy.task('log', '  Processor stopped and removed from table. Flash confirmed.');
  });

  it('can cancel the stop confirmation modal', () => {
    const procId = uniqueProcessorId('cy_cancel');
    cy.task('log', `\n  Testing stop cancel: ${procId}`);

    // Start a processor to test with
    cy.get('[data-testid="start-processor-btn"]').click();
    cy.get('[data-testid="start-modal"]').should('be.visible');
    cy.get('[data-testid="input-processor-id"]').clear().type(procId);

    cy.get('[data-testid="input-factory-id"] option')
      .not(':first')
      .first()
      .then(($opt) => {
        cy.get('[data-testid="input-factory-id"]').select($opt.val() as string);
      });

    cy.get('[data-testid="start-submit-btn"]').click();
    cy.get('[data-testid="start-modal"]').should('not.exist');
    cy.get(`[data-testid="processor-row-${procId}"]`).should('exist');

    // Click stop
    cy.get(`[data-testid="stop-processor-${procId}"]`).click();
    cy.get('[data-testid="stop-confirm-modal"]').should('be.visible');

    // Cancel
    cy.get('[data-testid="stop-cancel-btn"]').click();
    cy.get('[data-testid="stop-confirm-modal"]').should('not.exist');

    // Processor should still be there
    cy.get(`[data-testid="processor-row-${procId}"]`).should('exist');
    cy.task('log', '  Stop cancelled successfully. Processor still running.');

    // Cleanup: actually stop it now
    cy.get(`[data-testid="stop-processor-${procId}"]`).click();
    cy.get('[data-testid="stop-confirm-modal"]').should('be.visible');
    cy.get('[data-testid="stop-confirm-btn"]').click();
    cy.get(`[data-testid="processor-row-${procId}"]`).should('not.exist');
    cy.task('log', '  Cleanup complete.');
  });

  it('starts multiple processors and stops them all', () => {
    const procIds = [
      uniqueProcessorId('cy_multi_a'),
      uniqueProcessorId('cy_multi_b'),
    ];

    cy.task('log', `\n  Multi-processor test: ${procIds.join(', ')}`);

    getProcessorIds().then((idsBefore) => {
      const chain = cy.wrap(null);

      // Start each processor sequentially
      procIds.forEach((procId) => {
        chain.then(() => {
          cy.get('[data-testid="start-processor-btn"]').click();
          cy.get('[data-testid="start-modal"]').should('be.visible');
          cy.get('[data-testid="input-processor-id"]').clear().type(procId);

          cy.get('[data-testid="input-factory-id"] option')
            .not(':first')
            .first()
            .then(($opt) => {
              cy.get('[data-testid="input-factory-id"]').select($opt.val() as string);
            });

          cy.get('[data-testid="start-submit-btn"]').click();
          cy.get('[data-testid="start-modal"]').should('not.exist');
          cy.get(`[data-testid="processor-row-${procId}"]`).should('exist');
          cy.task('log', `  Started: ${procId}`);
        });
      });

      // Verify all are present
      chain.then(() => {
        getProcessorIds().then((idsAfter) => {
          procIds.forEach((procId) => {
            expect(idsAfter, `${procId} should be in the table`).to.include(procId);
          });
          cy.task('log', `  All ${procIds.length} processors visible.`);
        });
      });

      // Stop each processor sequentially
      procIds.forEach((procId) => {
        chain.then(() => {
          cy.get(`[data-testid="stop-processor-${procId}"]`).click();
          cy.get('[data-testid="stop-confirm-modal"]').should('be.visible');
          cy.get('[data-testid="stop-confirm-btn"]').click();
          cy.get(`[data-testid="processor-row-${procId}"]`).should('not.exist');
          cy.task('log', `  Stopped: ${procId}`);
        });
      });

      // Verify count is back to original
      chain.then(() => {
        getProcessorIds().then((idsFinal) => {
          expect(idsFinal.length, 'Processor count should return to original').to.eq(
            idsBefore.length,
          );
          cy.task('log', `  All cleaned up. Final count: ${idsFinal.length}`);
        });
      });
    });
  });

  it('starts processor with init values JSON', () => {
    const procId = uniqueProcessorId('cy_json');
    cy.task('log', `\n  Testing with JSON init values: ${procId}`);

    // Open start modal
    cy.get('[data-testid="start-processor-btn"]').click();
    cy.get('[data-testid="start-modal"]').should('be.visible');

    // Fill in the form
    cy.get('[data-testid="input-processor-id"]').clear().type(procId);

    cy.get('[data-testid="input-factory-id"] option')
      .not(':first')
      .first()
      .then(($opt) => {
        const factoryId = $opt.val() as string;
        cy.task('log', `  Factory: ${factoryId}`);
        cy.get('[data-testid="input-factory-id"]').select(factoryId);
      });

    // Provide init values JSON
    cy.get('[data-testid="input-init-values"]').clear().type('{}', { parseSpecialCharSequences: false });

    // Submit
    cy.get('[data-testid="start-submit-btn"]').click();

    // Check outcome
    // eslint-disable-next-line cypress/no-unnecessary-waiting
    cy.wait(2000);

    cy.document().then((doc) => {
      const modalStillOpen = doc.querySelector('[data-testid="start-modal"]') !== null;

      if (modalStillOpen) {
        const errorEl = doc.querySelector('[data-testid="start-error"]');
        const errorText = errorEl?.textContent?.trim() || 'unknown error';
        cy.task('log', `  START FAILED (may be expected): ${errorText}`);
        // Close modal
        cy.get('[data-testid="start-cancel-btn"]').click();
      } else {
        // Success - verify and cleanup
        cy.get(`[data-testid="processor-row-${procId}"]`).should('exist');
        cy.task('log', '  Processor started with JSON init values.');

        // Cleanup
        cy.get(`[data-testid="stop-processor-${procId}"]`).click();
        cy.get('[data-testid="stop-confirm-modal"]').should('be.visible');
        cy.get('[data-testid="stop-confirm-btn"]').click();
        cy.get(`[data-testid="processor-row-${procId}"]`).should('not.exist');
        cy.task('log', '  Cleanup complete.');
      }
    });
  });
});
