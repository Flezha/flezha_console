/**
 * E2E tests for the audit log screen.
 *
 * Covers:
 *   1. Statistics and the file catalog
 *   2. Filtered reads, including the no-match case
 *   3. The truncation notice when more records match than the limit
 *   4. The tail starting paused, streaming, and stopping
 *
 * Requires FLEZHA_AUDIT_ENABLED=true on the controller — the dev compose sets
 * it. With audit off the screen explains that instead, which is asserted too.
 */

/**
 * Runs `fn` only when the controller has audit logging on. The screen renders
 * an explanation instead when it is off, and that case is asserted separately.
 */
function whenEnabled(fn: () => void) {
  cy.get('body').then(($body) => {
    if ($body.find('[data-testid="audit-disabled"]').length > 0) {
      cy.task('log', '  Audit is disabled on the controller; skipping.');
    } else {
      fn();
    }
  });
}

describe('Audit log', () => {
  beforeEach(() => {
    cy.visitLive('/audit');
  });

  it('either shows the log or explains why it is off', () => {
    cy.get('body').then(($body) => {
      if ($body.find('[data-testid="audit-disabled"]').length > 0) {
        // The configuration state must name the flag, not just fail.
        cy.get('[data-testid="audit-disabled"]').should('contain.text', 'FLEZHA_');
        cy.task('log', '  Audit is disabled on the controller; explanation rendered.');
      } else {
        cy.get('[data-testid="audit-stats"]').should('exist');
        cy.task('log', '  Audit is enabled; stats rendered.');
      }
    });
  });

  it('reads records and shows them', () => {
    whenEnabled(() => {
      cy.get('[data-testid="audit-read-btn"]').click();

      // Reading the audit log is itself audited, so there is always at least
      // this UI's own activity to find.
      cy.get('[data-testid="audit-records"]')
        .should('exist')
        .and('contain.text', '"source":"ui"');
    });
  });

  it('reports when a filter matches nothing', () => {
    whenEnabled(() => {
      cy.get('[data-testid="audit-filter-source"]').clear().type('no_such_source');
      cy.get('[data-testid="audit-read-btn"]').click();

      cy.get('[data-testid="audit-records-empty"]')
        .should('exist')
        .and('contain.text', 'No record matches');
    });
  });

  it('says so when the result was truncated by the limit', () => {
    whenEnabled(() => {
      // A limit of 1 against a log that always has this UI's own reads in it.
      cy.get('[data-testid="audit-filter-limit"]').clear().type('1');
      cy.get('[data-testid="audit-read-btn"]').click();

      cy.get('[data-testid="audit-truncated"]')
        .should('exist')
        .and('contain.text', 'More records matched');
    });
  });

  it('starts the tail paused, streams, and stops cleanly', () => {
    whenEnabled(() => {
      // Paused by default: an idle tab must not hold a controller subscription.
      cy.get('[data-testid="audit-tail-idle"]').should('exist');
      cy.get('[data-testid="audit-tail-toggle"]').should('contain.text', 'Start tail');

      cy.get('[data-testid="audit-tail-toggle"]').click();
      cy.get('[data-testid="audit-tail-toggle"]').should('contain.text', 'Tailing');

      // Any audited action produces a record; reading is one.
      cy.get('[data-testid="audit-read-btn"]').click();
      cy.get('[data-testid="audit-tail-records"]', { timeout: 15000 })
        .should('exist')
        .and('contain.text', '"source":"ui"');

      cy.get('[data-testid="audit-tail-toggle"]').click();
      cy.get('[data-testid="audit-tail-idle"]').should('exist');
    });
  });
});
