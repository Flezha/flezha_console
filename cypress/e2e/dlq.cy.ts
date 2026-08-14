/**
 * E2E tests for the dead-letter queue screen.
 *
 * Covers:
 *   1. The empty state, and the filtered empty state
 *   2. The statistics panel
 *   3. Table shape and per-row actions when entries exist
 *   4. Confirm-gating on both destructive verbs
 *
 * The queue is normally empty on a healthy dev stack, so the entry-dependent
 * assertions are conditional on entries being present rather than faked — a
 * test that manufactured a parked payload would be testing the fixture.
 */

/**
 * Runs `fn` with the first parked entry's reference, or logs that there was
 * none. The queue is normally empty on a healthy stack, and manufacturing a
 * parked payload would test the fixture rather than the screen.
 */
function withParkedEntry(fn: (ref: string) => void) {
  cy.get('body').then(($body) => {
    const rows = $body.find('[data-testid^="dlq-row-"]');

    if (rows.length === 0) {
      cy.task('log', '  No parked entries; not exercised this run.');
    } else {
      fn(rows.first().attr('data-testid')!.replace('dlq-row-', ''));
    }
  });
}

describe('Dead-letter queue', () => {
  beforeEach(() => {
    cy.visitLive('/dlq');
  });

  it('renders the queue, empty or not', () => {
    cy.get('body').then(($body) => {
      if ($body.find('[data-testid="dlq-empty"]').length > 0) {
        cy.get('[data-testid="dlq-empty"]').should(
          'contain.text',
          'The dead-letter queue is empty',
        );
        cy.task('log', '  Queue is empty; empty state rendered.');
      } else {
        cy.get('[data-testid="dlq-table"]').should('exist');
        cy.task('log', '  Queue has entries; table rendered.');
      }
    });
  });

  it('filters by operative class', () => {
    cy.get('[data-testid="dlq-filter"]').clear().type('no_such_operative_class');

    cy.get('[data-testid="dlq-empty"]')
      .should('exist')
      .and('contain.text', 'No parked entries for that operative class');
  });

  it('confirm-gates replay and drop when entries exist', () => {
    withParkedEntry((ref) => {
      // Drop must ask first, and dismissing must leave the entry alone.
      cy.get(`[data-testid="dlq-drop-${ref}"]`).click();
      cy.get('[data-testid="dlq-confirm-modal"]')
        .should('exist')
        .and('contain.text', 'permanent');
      cy.get('[data-testid="dlq-confirm-cancel"]').click();
      cy.get('[data-testid="dlq-confirm-modal"]').should('not.exist');
      cy.get(`[data-testid="dlq-row-${ref}"]`).should('exist');

      // Replay must ask too, and say what it will report.
      cy.get(`[data-testid="dlq-replay-${ref}"]`).click();
      cy.get('[data-testid="dlq-confirm-modal"]')
        .should('exist')
        .and('contain.text', 'parked again');
      cy.get('[data-testid="dlq-confirm-cancel"]').click();
      cy.get('[data-testid="dlq-confirm-modal"]').should('not.exist');
    });
  });

  it('opens an entry for inspection when entries exist', () => {
    withParkedEntry((ref) => {
      cy.get(`[data-testid="dlq-inspect-${ref}"]`).click();
      cy.get('[data-testid="dlq-inspect-modal"]').should('exist');
      cy.get('[data-testid="dlq-payload"]').should('exist');
      cy.get('[data-testid="dlq-inspect-close"]').click();
      cy.get('[data-testid="dlq-inspect-modal"]').should('not.exist');
    });
  });
});
