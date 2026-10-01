import type { FullConfig } from '@playwright/test';

export default async function globalTeardown(_config: FullConfig): Promise<void> {
  // Playwright disposes browser contexts and APIRequestContexts at test teardown.
  // The local SQLite DB and failure artifacts are intentionally retained under
  // ignored test-results/ so a failure can be investigated after the run.
}
