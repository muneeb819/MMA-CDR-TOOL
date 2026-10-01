import { test, expect } from '../fixtures/test.js';
import { API_URL } from '../helpers/api.js';
import { isolatedCampaignId, telemetry } from '../helpers/test-data.js';
import type { TelemetryPayload } from '../helpers/types.js';

function websocketURL(): string {
  const url = new URL('/ws/v2/vici', API_URL);
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
  return url.toString();
}

async function exchangeFrames(frames: string[], url = websocketURL()): Promise<Array<Record<string, unknown>>> {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
    const results: Array<Record<string, unknown>> = [];
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      socket.close();
      reject(new Error('Timed out waiting for WebSocket response frames'));
    }, 10_000);
    socket.addEventListener('open', () => socket.send(frames[0]));
    socket.addEventListener('message', event => {
      results.push(JSON.parse(String(event.data)) as Record<string, unknown>);
      if (results.length < frames.length) {
        socket.send(frames[results.length]);
        return;
      }
      settled = true;
      clearTimeout(timer);
      socket.close(1000, 'test complete');
      resolve(results);
    });
    socket.addEventListener('error', () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      reject(new Error('WebSocket connection failed'));
    });
  });
}

async function connectAndClose(url = websocketURL()): Promise<number> {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url);
    const timer = setTimeout(() => {
      socket.close();
      reject(new Error('WebSocket did not open before timeout'));
    }, 5_000);
    socket.addEventListener('open', () => socket.close(1000, 'disconnect test'));
    socket.addEventListener('close', event => {
      clearTimeout(timer);
      resolve(event.code);
    });
    socket.addEventListener('error', () => {
      clearTimeout(timer);
      reject(new Error('WebSocket connection failed'));
    });
  });
}

test.describe('VICIdial telemetry WebSocket @api @telemetry @regression', () => {
  test('accepts a valid frame and returns raw telemetry plus analysis @smoke', async () => {
    const payload = telemetry({ campaign_id: isolatedCampaignId(), source_url: 'https://vicidial.test/ws/smoke' });
    const [response] = await exchangeFrames([JSON.stringify(payload)]);
    expect(response).toHaveProperty('raw');
    expect(response).toHaveProperty('ai_insights');
    expect((response.raw as Record<string, unknown>).source_url).toBe(payload.source_url);
    expect((response.ai_insights as Record<string, unknown>).status).toBe('HEALTHY');
  });

  test('handles sequential telemetry messages on one connection @regression', async () => {
    const campaign = isolatedCampaignId();
    const frames: TelemetryPayload[] = [
      telemetry({ campaign_id: campaign, drop_percent: 0, calls_in_queue: 0 }),
      telemetry({ campaign_id: campaign, drop_percent: 4.2, calls_in_queue: 2, agents_waiting: 0 }),
    ];
    const results = await exchangeFrames(frames.map(frame => JSON.stringify(frame)));
    expect(results).toHaveLength(2);
    expect((results[0].ai_insights as Record<string, unknown>).status).toBe('HEALTHY');
    expect((results[1].ai_insights as Record<string, unknown>).status).toBe('ACTION_REQUIRED');
  });

  test('malformed JSON and invalid telemetry return safe error frames and the connection recovers @security', async ({ api }) => {
    const valid = telemetry({ campaign_id: isolatedCampaignId() });
    const responses = await exchangeFrames(['{', '{}', JSON.stringify(valid)]);
    expect(responses[0]).toEqual({ error: 'invalid_json' });
    expect(responses[1].error).toBe('invalid_telemetry');
    expect(responses[1].detail).toBeTruthy();
    expect(responses[2]).toHaveProperty('ai_insights');
    expect((await api.get('/health')).status()).toBe(200);
  });

  test('a closed telemetry socket can reconnect and process another frame @regression', async () => {
    expect(await connectAndClose()).toBe(1000);
    const [response] = await exchangeFrames([JSON.stringify(telemetry({ campaign_id: isolatedCampaignId() }))]);
    expect(response).toHaveProperty('ai_insights');
  });
});
