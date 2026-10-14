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

  // Spec files run side by side, each test owning what it asserts on: relays
  // it started, records it sent, and its worker's own console user. Tests in
  // one file run in order, so a file can share one setup.
  fullyParallel: false,
  workers: Number(process.env.E2E_WORKERS ?? 4),

  // A test that only passes on a retry is a test that is lying about the state
  // it needs; failures here are meant to be read, not smoothed over.
  retries: 0,

  reporter: [['list'], ['html', { open: 'never' }]],

  // Caps, not budgets: a test waits only for what it caused, so a test that
  // needs longer is waiting on time and fails here.
  timeout: 20_000,
  expect: { timeout: 5_000 },

  use: {
    baseURL: process.env.E2E_BASE_URL ?? 'http://localhost:4000',
    viewport: { width: 1280, height: 720 },
    navigationTimeout: 10_000,
    actionTimeout: 5_000,
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
