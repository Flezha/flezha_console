import { defineConfig, devices } from '@playwright/test';

/**
 * The suite drives the running dev stack, so it asserts against a real
 * controller and a real runner rather than a fixture.
 *
 * Bring the stack up first:
 *   docker compose -f docker-compose.dev.yml up
 */
export default defineConfig({
  testDir: './e2e',

  // The dev stack is one controller with one shared `default` namespace and one
  // shared `testnet_store_1` operative. Several specs assert that a count
  // returns to its starting value — which is what catches a leaked operative or
  // binding — and concurrent workers mutating that state would make those
  // assertions lie in both directions.
  fullyParallel: false,
  workers: 1,

  // A test that only passes on a retry is a test that is lying about the state
  // it needs; failures here are meant to be read, not smoothed over.
  retries: 0,

  reporter: [['list'], ['html', { open: 'never' }]],

  expect: { timeout: 10_000 },

  use: {
    baseURL: 'http://localhost:4000',
    storageState: 'e2e/.auth/user.json',
    viewport: { width: 1280, height: 720 },
    navigationTimeout: 30_000,
    actionTimeout: 10_000,
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
  },

  globalSetup: './e2e/global-setup.ts',

  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});
