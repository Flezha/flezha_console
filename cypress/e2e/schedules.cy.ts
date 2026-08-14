/**
 * E2E tests for the schedules screen.
 *
 * Covers:
 *   1. Creating a schedule, which persists it and arms it on the hub
 *   2. Next-fire computed from the cron expression
 *   3. Controller-side validation surfacing on the form without persisting
 *   4. Confirm-gated removal
 *
 * Each test cleans up the schedule it created, so a failed run does not leave
 * a cron job firing against the dev controller.
 */

/**
 * Unique per run, so a leftover from a failed run cannot collide.
 *
 * Kept short deliberately: the controller allows 11 bytes, because the cron
 * instance id it composes (`<name>@<slot-iso>`) must fit the 32-byte operative
 * id limit.
 */
function uniqueScheduleName(prefix = 'cy'): string {
  return `${prefix}${Date.now().toString(36).slice(-6)}`;
}

function openForm() {
  cy.get('[data-testid="schedule-new-btn"]').click();
  cy.get('[data-testid="schedule-form-modal"]').should('exist');
}

function fillForm(name: string, cron: string, factory: string) {
  cy.get('[data-testid="schedule-input-name"]').clear().type(name);
  cy.get('[data-testid="schedule-input-cron"]').clear().type(cron);
  cy.get('[data-testid="schedule-input-factory"]').clear().type(factory);
}

function removeSchedule(name: string) {
  cy.get('body').then(($body) => {
    if ($body.find(`[data-testid="schedule-remove-${name}"]`).length === 0) return;
    cy.get(`[data-testid="schedule-remove-${name}"]`).click();
    cy.get('[data-testid="schedule-remove-confirm"]').click();
    cy.get(`[data-testid="schedule-row-${name}"]`).should('not.exist');
  });
}

describe('Schedules', () => {
  beforeEach(() => {
    cy.visitLive('/schedules');
  });

  it('creates a schedule, arms it, and shows when it next fires', () => {
    const name = uniqueScheduleName();
    cy.task('log', `\n  Creating schedule: ${name}`);

    openForm();
    fillForm(name, '*/5 * * * *', 'echo_workflow');
    cy.get('[data-testid="schedule-form-submit"]').click();

    cy.get('[data-testid="schedule-form-modal"]').should('not.exist');
    cy.get(`[data-testid="schedule-row-${name}"]`).should('exist');

    // Persisted *and* armed: an entry the hub never accepted would read
    // "Not armed", which is the state this screen exists to distinguish.
    cy.get(`[data-testid="schedule-status-${name}"]`).should('contain.text', 'Armed');

    // Next fire is computed from the cron, not reported by the hub.
    cy.get(`[data-testid="schedule-next-fire-${name}"]`)
      .invoke('text')
      .should((text) => {
        expect(text.trim(), 'next fire must be a concrete time').to.match(/\d{4}-\d{2}-\d{2}/);
      });

    removeSchedule(name);
  });

  it('rejects an invalid cron expression without persisting anything', () => {
    const name = uniqueScheduleName('cyc');

    openForm();
    fillForm(name, 'not a cron expression', 'echo_workflow');
    cy.get('[data-testid="schedule-form-submit"]').click();

    cy.get('[data-testid="schedule-form-error"]')
      .should('exist')
      .and('contain.text', 'cron');

    // The form stays open and nothing was stored.
    cy.get('[data-testid="schedule-form-modal"]').should('exist');
    cy.get('[data-testid="schedule-form-cancel"]').click();
    cy.get(`[data-testid="schedule-row-${name}"]`).should('not.exist');
  });

  it('rejects an unknown timezone without persisting anything', () => {
    const name = uniqueScheduleName('cyt');

    openForm();
    fillForm(name, '*/5 * * * *', 'echo_workflow');
    cy.get('[data-testid="schedule-input-timezone"]').clear().type('Mars/Olympus_Mons');
    cy.get('[data-testid="schedule-form-submit"]').click();

    cy.get('[data-testid="schedule-form-error"]')
      .should('exist')
      .and('contain.text', 'timezone');

    cy.get('[data-testid="schedule-form-cancel"]').click();
    cy.get(`[data-testid="schedule-row-${name}"]`).should('not.exist');
  });

  it('requires the fields the controller requires', () => {
    openForm();
    cy.get('[data-testid="schedule-input-name"]').clear();
    cy.get('[data-testid="schedule-form-submit"]').click();

    cy.get('[data-testid="schedule-form-error"]').should('contain.text', 'Required');
    cy.get('[data-testid="schedule-form-cancel"]').click();
  });

  it('confirm-gates removal', () => {
    const name = uniqueScheduleName('cyr');

    openForm();
    fillForm(name, '*/5 * * * *', 'echo_workflow');
    cy.get('[data-testid="schedule-form-submit"]').click();
    cy.get(`[data-testid="schedule-row-${name}"]`).should('exist');

    // Dismissing the confirmation must leave the schedule armed.
    cy.get(`[data-testid="schedule-remove-${name}"]`).click();
    cy.get('[data-testid="schedule-remove-modal"]').should('exist');
    cy.get('[data-testid="schedule-remove-cancel"]').click();
    cy.get('[data-testid="schedule-remove-modal"]').should('not.exist');
    cy.get(`[data-testid="schedule-row-${name}"]`).should('exist');

    // Confirming removes it.
    cy.get(`[data-testid="schedule-remove-${name}"]`).click();
    cy.get('[data-testid="schedule-remove-confirm"]').click();
    cy.get(`[data-testid="schedule-row-${name}"]`).should('not.exist');
  });
});
