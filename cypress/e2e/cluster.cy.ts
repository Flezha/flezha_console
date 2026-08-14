/**
 * E2E tests for the cluster and fleet screen.
 *
 * Covers:
 *   1. Node membership, with the connected controller marked
 *   2. Per-namespace hub placement
 *   3. The runner fleet and each runner's registered factories
 *   4. Factory placement lookup, and clearing it
 *
 * Requires a running controller with at least one connected runner.
 */

describe('Cluster and fleet', () => {
  beforeEach(() => {
    cy.visitLive('/cluster');
  });

  it('lists cluster nodes and marks the one this UI is connected to', () => {
    cy.get('[data-testid="cluster-nodes"]').should('exist');
    cy.get('[data-testid="cluster-nodes"] li').should('have.length.at.least', 1);
    cy.get('[data-testid="cluster-nodes"]').should('contain.text', 'connected to this UI');
  });

  it('shows hub placement for each running namespace', () => {
    cy.get('[data-testid="cluster-namespace-default"]').should('exist');

    cy.get('[data-testid="hub-nodes-default"]')
      .invoke('text')
      .should((text) => {
        expect(text.trim(), 'hub cell must say something definite').to.not.equal('');
      });
  });

  it('lists the runners serving a namespace with their factories', () => {
    cy.get('[data-testid="runners-default"]').should('exist');

    cy.get('[data-testid="runners-default"] li')
      .should('have.length.at.least', 1)
      .first()
      .invoke('text')
      .should((text) => {
        // A connected runner registers the test factories; an empty factory
        // list would mean the handshake completed but registration did not.
        expect(text).to.contain('store_input');
      });
  });

  it('looks up which runners serve a factory, and clears the selection', () => {
    cy.get('[data-testid="factory-store_input"]').click();

    cy.get('[data-testid="factory-runners"]')
      .should('exist')
      .and('contain.text', 'store_input')
      .and('contain.text', 'is served by');

    cy.contains('button', 'Clear').click();
    cy.get('[data-testid="factory-runners"]').should('not.exist');
  });
});

// Not covered here: the "no runner serves this factory" state. Every factory
// the screen offers comes from a connected runner, so producing it would mean
// stopping the runner mid-suite and destabilising every other spec.

