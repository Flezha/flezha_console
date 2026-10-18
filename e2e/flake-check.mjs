#!/usr/bin/env node
/**
 * Runs the whole browser suite several times with its normal workers and
 * lists every test that failed in any run or whose outcome differed between
 * runs. Exits non-zero when that list, or any run's own error, is not empty.
 *
 *   npm run e2e:flake-check               # 3 runs
 *   npm run e2e:flake-check -- 5          # 5 runs
 *   npm run e2e:flake-check -- 3 access   # 3 runs of the files matching `access`
 *
 * Arguments after the run count go to `playwright test` as they are. A run
 * that ran no test, such as one refused in global setup, is reported as a run
 * error and left out of the comparison.
 */
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

const argv = process.argv.slice(2);
const runs = /^\d+$/.test(argv[0] ?? '') ? Number(argv.shift()) : 3;
if (runs < 2) throw new Error('a flake check needs at least 2 runs');
if (argv.some((arg) => arg.startsWith('--repeat-each'))) {
  throw new Error('the flake check repeats whole runs: give it a run count instead of --repeat-each');
}

const dir = mkdtempSync(path.join(tmpdir(), 'flz-flake-'));
/** test key → outcome in each run, by run index */
const outcomes = new Map();
const runErrors = [];
const seconds = [];
/** The runs that ran tests, the only ones compared. */
const ran = [];

try {
  for (let run = 0; run < runs; run++) {
    const file = path.join(dir, `run-${run}.json`);
    console.log(`\n── run ${run + 1} of ${runs}`);

    const started = performance.now();
    spawnSync('npx', ['playwright', 'test', '--reporter=dot,json', ...argv], {
      stdio: 'inherit',
      env: { ...process.env, PLAYWRIGHT_JSON_OUTPUT_FILE: file },
    });
    seconds.push((performance.now() - started) / 1000);

    let report;
    try {
      report = JSON.parse(readFileSync(file, 'utf8'));
    } catch {
      runErrors.push(`run ${run + 1}: wrote no report`);
      continue;
    }

    for (const error of report.errors ?? []) runErrors.push(`run ${run + 1}: ${firstLine(error.message)}`);
    const tests = [...testsOf(report)];
    if (tests.length === 0) {
      runErrors.push(`run ${run + 1}: ran no test`);
      continue;
    }
    ran.push(run);
    for (const [key, status] of tests) {
      if (!outcomes.has(key)) outcomes.set(key, Array(runs).fill('not run'));
      outcomes.get(key)[run] = status;
    }
  }
} finally {
  rmSync(dir, { recursive: true, force: true });
}

const listed = [...outcomes]
  .map(([key, each]) => [key, ran.map((run) => each[run])])
  .filter(([, each]) => each.some((s) => s === 'unexpected' || s === 'flaky') || new Set(each).size > 1);

const sorted = [...seconds].sort((a, b) => a - b);
console.log(`\nWall time per run: ${seconds.map((s) => `${s.toFixed(1)} s`).join(', ')}`);
console.log(`Median: ${sorted[Math.floor(sorted.length / 2)].toFixed(1)} s`);

if (listed.length === 0 && runErrors.length === 0) {
  console.log(`\nEvery one of ${outcomes.size} tests had the same outcome in all ${runs} runs.`);
} else {
  for (const line of runErrors) console.log(line);
  if (listed.length) console.log(`\n${listed.length} test(s) failed or changed outcome:`);
  for (const [key, each] of listed) {
    const failedIn = each.flatMap((s, i) => (s === 'expected' || s === 'skipped' ? [] : [ran[i] + 1]));
    console.log(`  ${key}\n    ${each.join(' | ')}  (not passing in run ${failedIn.join(', ')})`);
  }
  process.exitCode = 1;
}

/** Each test of `report` with its outcome: expected, unexpected, flaky or skipped. */
function* testsOf(report) {
  function* walk(suite, titles) {
    for (const spec of suite.specs ?? []) {
      for (const test of spec.tests) {
        yield [`[${test.projectName}] ${spec.file} › ${[...titles, spec.title].join(' › ')}`, test.status];
      }
    }
    for (const child of suite.suites ?? []) yield* walk(child, [...titles, child.title]);
  }
  for (const file of report.suites ?? []) yield* walk(file, []);
}

function firstLine(message = '') {
  return message.split('\n').find((line) => line.trim()) ?? message;
}
