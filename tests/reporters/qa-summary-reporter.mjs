import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';

const categories = [
  ['Frontend', /@e2e|tests\/e2e\//i],
  ['API', /@api|tests\/api\//i],
  ['Scrubber', /@scrubber|scrubber|upload/i],
  ['Phone Extraction', /@phone-extraction|phone.?extract|candidate/i],
  ['Refinery', /@refinery|refine|normalize|fingerprint/i],
  ['Deduplication', /@dedupe|duplicate/i],
  ['Suppression', /@suppression|suppress/i],
  ['Scoring', /@scoring|score|decision/i],
  ['Telemetry', /@telemetry|telemetry/i],
  ['WebSocket', /websocket|@websocket/i],
  ['Database', /@database|tests\/database\//i],
  ['Security', /@security/i],
  ['Performance', /@performance/i],
  ['Regression', /@regression/i],
];

const endpointByFile = [
  [/scrubber\.spec\.ts/, 'POST /api/v2/scrubber/upload'],
  [/refine\.spec\.ts/, 'POST /api/v2/refine; POST /api/v2/score'],
  [/telemetry\.spec\.ts/, 'POST /api/v2/telemetry; GET /api/v2/telemetry/recent; GET /api/v2/campaigns/{campaign_id}/summary'],
  [/websocket\.spec\.ts/, 'WS /ws/v2/vici'],
  [/health\.spec\.ts/, 'GET /health; GET /openapi.json'],
  [/sqlite\.spec\.ts/, 'SQLite persistence exercised through the API'],
  [/sqlserver\.spec\.ts/, 'SQL Server schema and transaction integration'],
  [/full-flow\.spec\.ts/, 'POST /api/v2/scrubber/upload; POST /api/v2/refine; POST /api/v2/score; POST /api/v2/telemetry'],
  [/workflows\.spec\.ts/, 'POST /api/v2/scrubber/upload; POST /api/v2/refine; POST /api/v2/score; POST /api/v2/telemetry; GET /api/v2/telemetry/recent; GET /api/v2/campaigns/{campaign_id}/summary'],
];

export default class QaSummaryReporter {
  constructor() {
    this.tests = new Map();
    this.startedAt = Date.now();
  }

  onBegin(_config, suite) {
    this.expectedTests = suite.allTests().length;
  }

  onTestEnd(test, result) {
    const title = test.titlePath().join(' › ');
    const annotations = [...(test.annotations || []), ...(result.annotations || [])];
    const file = path.relative(process.cwd(), test.location.file).replaceAll('\\', '/');
    const matchingEndpoint = endpointByFile.find(([pattern]) => pattern.test(file));
    const attachments = (result.attachments || []).map(attachment => attachment.path
      ? path.relative(process.cwd(), attachment.path).replaceAll('\\', '/')
      : attachment.name);
    this.tests.set(test.id, {
      title,
      file,
      status: result.status,
      duration: result.duration,
      retry: result.retry,
      error: result.error?.message || result.errors?.map(error => error.message).filter(Boolean).join('\n') || '',
      endpoint: annotations.find(annotation => annotation.type === 'endpoint')?.description || matchingEndpoint?.[1] || 'Not isolated; see test file.',
      databaseObject: annotations.find(annotation => annotation.type === 'database-object')?.description
        || (file.includes('sqlite.spec') || file.includes('workflows.spec') ? 'SQLite tables: upload_batches, raw_records, decisions, telemetry_snapshots, alerts (when local SQLite is active)'
          : file.includes('sqlserver.spec') ? 'SQL Server dbo tables, constraints, indexes, procedures and views'
            : 'Not directly exercised.'),
      skipReason: annotations.find(annotation => annotation.type === 'skip')?.description || '',
      attachments,
      categories: categories.filter(([, pattern]) => pattern.test(`${title} ${file}`)).map(([name]) => name),
    });
  }

  async onEnd() {
    const tests = [...this.tests.values()];
    const totals = countStatuses(tests);
    const duration = Date.now() - this.startedAt;
    const featureRows = categories.map(([name]) => {
      const subset = tests.filter(item => item.categories.includes(name));
      return `| ${name} | ${subset.length} | ${countStatuses(subset).passed} | ${countStatuses(subset).failed} | ${countStatuses(subset).skipped} |`;
    });
    const failures = tests.filter(item => item.status !== 'passed' && item.status !== 'skipped');
    const skipped = tests.filter(item => item.status === 'skipped');
    const lines = [
      '# MMA-CDR TOOL QA Run Summary',
      '',
      `Generated: ${new Date().toISOString()}`,
      '',
      '## Totals',
      '',
      `- **TOTAL TESTS:** ${tests.length} (discovered: ${this.expectedTests ?? tests.length})`,
      `- **PASSED:** ${totals.passed}`,
      `- **FAILED:** ${totals.failed + totals.timedOut + totals.interrupted}`,
      `- **SKIPPED:** ${totals.skipped}`,
      `- **DURATION:** ${(duration / 1000).toFixed(2)} seconds`,
      '',
      '## Feature breakdown',
      '',
      '| Area | Total | Passed | Failed | Skipped |',
      '|---|---:|---:|---:|---:|',
      ...featureRows,
      '',
      '## Failures',
      '',
      ...(failures.length ? failures.flatMap(item => [
        `### ${escapeMarkdown(item.title)}`,
        '',
        `- Status: **${item.status}**${item.retry ? ` (retry ${item.retry})` : ''}`,
        `- Endpoint involved: ${escapeMarkdown(item.endpoint)}`,
        `- File involved: \`${escapeMarkdown(item.file)}\``,
        `- Database object involved: ${escapeMarkdown(item.databaseObject)}`,
        `- Failure reason: ${escapeMarkdown(item.error || 'See Playwright result for details.')}`,
        `- Suggested root cause: **Root cause requires investigation.**`,
        `- Screenshot / trace / video: ${item.attachments.length ? item.attachments.map(value => `\`${escapeMarkdown(value)}\``).join(', ') : 'No failure attachment recorded.'}`,
        '',
      ]) : ['No failed tests in this run.', '']),
      '## Skips / infrastructure boundaries',
      '',
      ...(skipped.length ? skipped.map(item => `- ${escapeMarkdown(item.title)} — ${escapeMarkdown(item.skipReason || 'Optional infrastructure or explicit test skip.')}`) : ['No skipped tests.']),
      '',
      'Reports: `playwright-report/index.html`, `test-results/results.json`, and `test-results/junit.xml`.',
      '',
    ];

    const output = path.resolve('test-results/qa-summary.md');
    await mkdir(path.dirname(output), { recursive: true });
    await writeFile(output, `${lines.join('\n')}\n`, 'utf8');
  }
}

function countStatuses(tests) {
  const result = { passed: 0, failed: 0, timedOut: 0, skipped: 0, interrupted: 0, flaky: 0 };
  for (const test of tests) {
    if (test.status in result) result[test.status] += 1;
    if (test.status === 'passed' && test.retry > 0) result.flaky += 1;
  }
  return result;
}

function escapeMarkdown(value) {
  return String(value).replaceAll('|', '\\|').replaceAll('\n', ' ');
}
