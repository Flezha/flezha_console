declare global {
  namespace Cypress {
    interface Chainable {
      login(): Chainable<void>;
      waitForLiveView(): Chainable<JQuery<HTMLElement>>;
      visitLive(path: string): Chainable<JQuery<HTMLElement>>;
    }
  }
}

Cypress.Commands.add('login', () => {
  cy.session('dev-user', () => {
    cy.visit('/users/log-in');
    cy.get('#login_form_password').within(() => {
      cy.get('input[name="user[email]"]').type('dev@flezha.local');
      cy.get('input[name="user[password]"]').type('dev_password_123');
      cy.get('button').contains('Log in').click();
    });
    cy.url().should('eq', Cypress.config('baseUrl') + '/');
  });
});

/** Log in, open a screen, and wait for its LiveView to connect. */
Cypress.Commands.add('visitLive', (path: string) => {
  cy.login();
  cy.visit(path);
  return cy.waitForLiveView();
});

Cypress.Commands.add('waitForLiveView', () => {
  cy.get('[data-phx-main]', { timeout: 15000 })
    .should('exist')
    .and('not.have.class', 'phx-loading');
});

export {};
