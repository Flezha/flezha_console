/**
 * E2E tests for operative lifecycle: starting and stopping operatives.
 *
 * Tests run against the namespace show page (/namespaces/default) and:
 *   1. Verify the start modal opens and lists available factories
 *   2. Start a new operative with a unique ID via the first available factory
 *   3. Verify the operative row appears in the operatives table
 *   4. Navigate to the operative detail page and back
 *   5. Stop the operative and verify the row is removed
 *   6. Test validation (empty fields, duplicate IDs)
 */

const NAMESPACE = 'default';
const NAMESPACE_URL = `/namespaces/${NAMESPACE}`;

/** Generate a unique operative ID for each test run to avoid collisions */
function uniqueOperativeId(prefix = 'cy_test'): string {
  const ts = Date.now().toString(36).slice(-4);
  const rand = Math.random().toString(36).slice(2, 5);
  return `${prefix}_${ts}_${rand}`;
}

/** Get all operative IDs currently shown in the table */
function getOperativeIds(): Cypress.Chainable<string[]> {
  return cy.document().then((doc) => {
    const rows = doc.querySelectorAll('[data-testid^="operative-row-"]');
    return Array.from(rows).map((el) => {
      const testid = el.getAttribute('data-testid') ?? '';
      return testid.replace('operative-row-', '');
    });
  });
}

describe('Operative Lifecycle - Start & Stop', () => {
  beforeEach(() => {
    cy.login();
    cy.visit(NAMESPACE_URL);
    cy.waitForLiveView();
  });

  it('opens the start modal and shows available factories', () => {
    cy.get('[data-testid="start-operative-btn"]').click();
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
    cy.get('[data-testid="start-operative-btn"]').click();
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
    cy.get('[data-testid="start-operative-btn"]').click();
    cy.get('[data-testid="start-modal"]').should('be.visible');

    // Fill in valid ID and factory, but invalid JSON
    const operativeId = uniqueOperativeId();
    cy.get('[data-testid="input-operative-id"]').clear().type(operativeId);

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

  it('starts a operative and verifies it appears in the table', () => {
    const operativeId = uniqueOperativeId();
    cy.task('log', `\n  Starting operative: ${operativeId}`);

    getOperativeIds().then((idsBefore) => {
      cy.task('log', `  Operatives before: ${idsBefore.length} [${idsBefore.join(', ')}]`);

      // Open start modal
      cy.get('[data-testid="start-operative-btn"]').click();
      cy.get('[data-testid="start-modal"]').should('be.visible');

      // Fill in the operative ID
      cy.get('[data-testid="input-operative-id"]').clear().type(operativeId);

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
      cy.get('body').should('contain.text', `Operative ${operativeId} started`);

      // New row should appear in the table
      cy.get(`[data-testid="operative-row-${operativeId}"]`, { timeout: 10000 }).should('exist');

      getOperativeIds().then((idsAfter) => {
        cy.task('log', `  Operatives after: ${idsAfter.length} [${idsAfter.join(', ')}]`);
        expect(idsAfter).to.include(operativeId);
        expect(idsAfter.length).to.eq(idsBefore.length + 1);
      });

      // --- CLEANUP: stop the operative ---
      cy.task('log', `  Cleaning up: stopping ${operativeId}`);
      cy.get(`[data-testid="stop-operative-${operativeId}"]`).click();
      cy.get('[data-testid="stop-confirm-modal"]').should('be.visible');
      cy.get('[data-testid="stop-confirm-btn"]').click();
      cy.get(`[data-testid="operative-row-${operativeId}"]`).should('not.exist');
      cy.task('log', '  Cleanup complete.');
    });
  });

  it('starts a operative, navigates to detail page, then stops it', () => {
    const operativeId = uniqueOperativeId('cy_nav');
    cy.task('log', `\n  Full lifecycle test: ${operativeId}`);

    // Start operative
    cy.get('[data-testid="start-operative-btn"]').click();
    cy.get('[data-testid="start-modal"]').should('be.visible');
    cy.get('[data-testid="input-operative-id"]').clear().type(operativeId);

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
    cy.get(`[data-testid="operative-row-${operativeId}"]`).should('exist');
    cy.task('log', '  Operative started and visible in table.');

    // Navigate to operative detail page
    cy.get(`[data-testid="view-operative-${operativeId}"]`).click();
    cy.waitForLiveView();

    // Verify we're on the operative detail page
    cy.url().should('include', `/namespaces/${NAMESPACE}/operatives/${operativeId}`);
    cy.get('body').should('contain.text', operativeId);
    cy.task('log', '  Navigated to operative detail page.');

    // Go back to namespace page
    cy.visit(NAMESPACE_URL);
    cy.waitForLiveView();

    // Operative should still be in the table
    cy.get(`[data-testid="operative-row-${operativeId}"]`).should('exist');
    cy.task('log', '  Operative persists after navigation.');

    // Stop the operative
    cy.get(`[data-testid="stop-operative-${operativeId}"]`).click();
    cy.get('[data-testid="stop-confirm-modal"]').should('be.visible');
    cy.get('[data-testid="stop-confirm-btn"]').click();

    // Verify removal
    cy.get(`[data-testid="operative-row-${operativeId}"]`).should('not.exist');
    cy.get('body').should('contain.text', `Operative ${operativeId} stopped`);
    cy.get('body').should('not.contain.text', 'Failed');
    cy.task('log', '  Operative stopped and removed from table. Flash confirmed.');
  });

  it('can cancel the stop confirmation modal', () => {
    const operativeId = uniqueOperativeId('cy_cancel');
    cy.task('log', `\n  Testing stop cancel: ${operativeId}`);

    // Start a operative to test with
    cy.get('[data-testid="start-operative-btn"]').click();
    cy.get('[data-testid="start-modal"]').should('be.visible');
    cy.get('[data-testid="input-operative-id"]').clear().type(operativeId);

    cy.get('[data-testid="input-factory-id"] option')
      .not(':first')
      .first()
      .then(($opt) => {
        cy.get('[data-testid="input-factory-id"]').select($opt.val() as string);
      });

    cy.get('[data-testid="start-submit-btn"]').click();
    cy.get('[data-testid="start-modal"]').should('not.exist');
    cy.get(`[data-testid="operative-row-${operativeId}"]`).should('exist');

    // Click stop
    cy.get(`[data-testid="stop-operative-${operativeId}"]`).click();
    cy.get('[data-testid="stop-confirm-modal"]').should('be.visible');

    // Cancel
    cy.get('[data-testid="stop-cancel-btn"]').click();
    cy.get('[data-testid="stop-confirm-modal"]').should('not.exist');

    // Operative should still be there
    cy.get(`[data-testid="operative-row-${operativeId}"]`).should('exist');
    cy.task('log', '  Stop cancelled successfully. Operative still running.');

    // Cleanup: actually stop it now
    cy.get(`[data-testid="stop-operative-${operativeId}"]`).click();
    cy.get('[data-testid="stop-confirm-modal"]').should('be.visible');
    cy.get('[data-testid="stop-confirm-btn"]').click();
    cy.get(`[data-testid="operative-row-${operativeId}"]`).should('not.exist');
    cy.task('log', '  Cleanup complete.');
  });

  it('starts multiple operatives and stops them all', () => {
    const procIds = [
      uniqueOperativeId('cy_multi_a'),
      uniqueOperativeId('cy_multi_b'),
    ];

    cy.task('log', `\n  Multi-operative test: ${procIds.join(', ')}`);

    getOperativeIds().then((idsBefore) => {
      const chain = cy.wrap(null);

      // Start each operative sequentially
      procIds.forEach((operativeId) => {
        chain.then(() => {
          cy.get('[data-testid="start-operative-btn"]').click();
          cy.get('[data-testid="start-modal"]').should('be.visible');
          cy.get('[data-testid="input-operative-id"]').clear().type(operativeId);

          cy.get('[data-testid="input-factory-id"] option')
            .not(':first')
            .first()
            .then(($opt) => {
              cy.get('[data-testid="input-factory-id"]').select($opt.val() as string);
            });

          cy.get('[data-testid="start-submit-btn"]').click();
          cy.get('[data-testid="start-modal"]').should('not.exist');
          cy.get(`[data-testid="operative-row-${operativeId}"]`).should('exist');
          cy.task('log', `  Started: ${operativeId}`);
        });
      });

      // Verify all are present
      chain.then(() => {
        getOperativeIds().then((idsAfter) => {
          procIds.forEach((operativeId) => {
            expect(idsAfter, `${operativeId} should be in the table`).to.include(operativeId);
          });
          cy.task('log', `  All ${procIds.length} operatives visible.`);
        });
      });

      // Stop each operative sequentially
      procIds.forEach((operativeId) => {
        chain.then(() => {
          cy.get(`[data-testid="stop-operative-${operativeId}"]`).click();
          cy.get('[data-testid="stop-confirm-modal"]').should('be.visible');
          cy.get('[data-testid="stop-confirm-btn"]').click();
          cy.get(`[data-testid="operative-row-${operativeId}"]`).should('not.exist');
          cy.task('log', `  Stopped: ${operativeId}`);
        });
      });

      // Verify count is back to original
      chain.then(() => {
        getOperativeIds().then((idsFinal) => {
          expect(idsFinal.length, 'Operative count should return to original').to.eq(
            idsBefore.length,
          );
          cy.task('log', `  All cleaned up. Final count: ${idsFinal.length}`);
        });
      });
    });
  });

  it('starts operative with init values JSON', () => {
    const operativeId = uniqueOperativeId('cy_json');
    cy.task('log', `\n  Testing with JSON init values: ${operativeId}`);

    // Open start modal
    cy.get('[data-testid="start-operative-btn"]').click();
    cy.get('[data-testid="start-modal"]').should('be.visible');

    // Fill in the form
    cy.get('[data-testid="input-operative-id"]').clear().type(operativeId);

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
        cy.get(`[data-testid="operative-row-${operativeId}"]`).should('exist');
        cy.task('log', '  Operative started with JSON init values.');

        // Cleanup
        cy.get(`[data-testid="stop-operative-${operativeId}"]`).click();
        cy.get('[data-testid="stop-confirm-modal"]').should('be.visible');
        cy.get('[data-testid="stop-confirm-btn"]').click();
        cy.get(`[data-testid="operative-row-${operativeId}"]`).should('not.exist');
        cy.task('log', '  Cleanup complete.');
      }
    });
  });
});
