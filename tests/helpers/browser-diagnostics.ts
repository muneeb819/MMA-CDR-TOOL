import type { Page, Request } from '@playwright/test';

export type BrowserDiagnostics = {
  consoleErrors: string[];
  pageErrors: string[];
  failedCriticalRequests: string[];
};

export function captureBrowserDiagnostics(page: Page): BrowserDiagnostics {
  const diagnostics: BrowserDiagnostics = { consoleErrors: [], pageErrors: [], failedCriticalRequests: [] };
  page.on('console', message => {
    if (message.type() === 'error') diagnostics.consoleErrors.push(message.text());
  });
  page.on('pageerror', error => diagnostics.pageErrors.push(error.message));
  page.on('requestfailed', request => {
    if (isCriticalRequest(request)) {
      diagnostics.failedCriticalRequests.push(`${request.method()} ${request.url()} — ${request.failure()?.errorText || 'request failed'}`);
    }
  });
  return diagnostics;
}

function isCriticalRequest(request: Request): boolean {
  const url = new URL(request.url());
  return url.pathname === '/' || url.pathname === '/health' || url.pathname.startsWith('/api/');
}
