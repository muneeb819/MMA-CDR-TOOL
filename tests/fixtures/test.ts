import { test as base, request, type APIRequestContext } from '@playwright/test';

export type TestFixtures = {
  api: APIRequestContext;
};

export const test = base.extend<TestFixtures>({
  api: async ({}, use) => {
    const context = await request.newContext({
      baseURL: process.env.API_URL || 'http://127.0.0.1:8000',
      extraHTTPHeaders: { Accept: 'application/json' },
      timeout: 20_000,
    });
    await use(context);
    await context.dispose();
  },
});

export { expect } from '@playwright/test';
