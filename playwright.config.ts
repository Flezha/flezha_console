import { defineConfig, devices } from '@playwright/test';

/**
 * The suite drives the running dev stack, so it asserts against a real
 * controller and a real runner rather than a fixture.
 *
 * Bring the stack up first:
 *   docker compose -f docker-compose.dev.yml up
 *
 * `E2E_BASE_URL` points the suite at a stack published on another port.
 */
const MARKET_STACK = process.env.E2E_MARKET_STACK === '1';

export default defineConfig({
  testDir: './e2e',

  // The dev stack is one controller with one shared `default` namespace and one
  // shared `testnet_store_1` relay. Several specs assert that a count
  // returns to its starting value — which is what catches a leaked relay or
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
    baseURL: process.env.E2E_BASE_URL ?? 'http://localhost:4000',
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
      // With the market stack named, its spec runs in its own project below;
      // without it, the spec runs here and skips, saying why.
      testIgnore: MARKET_STACK ? ['phone.spec.ts', 'relay-data-flow.spec.ts'] : 'phone.spec.ts',
    },
    // flezha_trader's dev stack, which runs this console on its own port.
    ...(MARKET_STACK
      ? [
          {
            name: 'market',
            use: {
              ...devices['Desktop Chrome'],
              baseURL: process.env.E2E_MARKET_URL ?? 'http://localhost:4000',
              storageState: 'e2e/.auth/market.json',
            },
            testMatch: 'relay-data-flow.spec.ts',
          },
        ]
      : []),
    {
      // A phone held in portrait: touch, a coarse pointer and a mobile viewport.
      name: 'phone',
      use: {
        ...devices['Pixel 7'],
        viewport: { width: 390, height: 844 },
        deviceScaleFactor: 3,
      },
      testMatch: 'phone.spec.ts',
    },
  ],
});
