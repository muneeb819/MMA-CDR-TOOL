import { test, expect } from '../fixtures/test.js';
import { expectStatus, TEST_TENANT_ID, uploadFile } from '../helpers/api.js';
import { fixture } from '../helpers/files.js';

const supportedSamples: Array<{ title: string; name: string; phones: number; parser: RegExp }> = [
  { title: 'CSV', name: 'phones.csv', phones: 3, parser: /^TEXT_TABLE$/ },
  { title: 'TSV', name: 'phones.tsv', phones: 2, parser: /^TEXT_TABLE$/ },
  { title: 'TXT', name: 'phones.txt', phones: 2, parser: /^TEXT_TABLE$/ },
  { title: 'LOG', name: 'phones.log', phones: 2, parser: /^TEXT_TABLE$/ },
  { title: 'JSON', name: 'phones.json', phones: 2, parser: /^JSON$/ },
  { title: 'JSON Lines', name: 'phones.jsonl', phones: 2, parser: /^JSON$/ },
  { title: 'XML', name: 'phones.xml', phones: 2, parser: /^XML$/ },
  { title: 'HTML', name: 'phones.html', phones: 2, parser: /^HTML$/ },
  { title: 'XLSX', name: 'phones.xlsx', phones: 2, parser: /^SPREADSHEET$/ },
  { title: 'Parquet', name: 'phones.parquet', phones: 2, parser: /^PARQUET$/ },
  { title: 'PDF', name: 'phones.pdf', phones: 1, parser: /^PDF$/ },
  { title: 'DOCX', name: 'phones.docx', phones: 2, parser: /^DOCX$/ },
  { title: 'ZIP with nested files', name: 'phones.zip', phones: 3, parser: /^ARCHIVE$/ },
  { title: 'unknown/custom text extension', name: 'phones.custom', phones: 1, parser: /^GENERIC_TEXT$/ },
  { title: 'unknown binary extension', name: 'binary.custom', phones: 0, parser: /^(?:GENERIC_TEXT|RAW_BINARY)$/ },
];

test.describe('Universal scrubber upload @api @scrubber @regression', () => {
  test('CSV upload returns the real response contract and stages candidates @smoke', async ({ api }) => {
    const { response, body } = await uploadFile(api, 'phones.csv', fixture('phones.csv'));
    await expectStatus(response, 200);
    expect(body).toMatchObject({ ok: true, extension: 'csv', parser: 'TEXT_TABLE', rows_scanned: 4, phone_candidates: 3 });
    expect(body.upload_batch_id).toMatch(/^[0-9a-f-]{36}$/i);
    expect(body.sample).toEqual(['+14155550132', '+12125550111', '+13105550123']);
  });

  for (const sample of supportedSamples) {
    test(`${sample.title} parser extracts its known fixture @regression`, async ({ api }) => {
      const { response, body } = await uploadFile(api, sample.name, fixture(sample.name));
      await expectStatus(response, 200);
      expect(body.ok).toBe(true);
      expect(body.parser).toMatch(sample.parser);
      expect(body.phone_candidates).toBe(sample.phones);
      expect(body.upload_batch_id).toBeTruthy();
    });
  }

  for (const extension of ['xls', 'xlsb', 'ods']) {
    test(`${extension.toUpperCase()} reader failures return a controlled extraction error @regression`, async ({ api }) => {
      const { response } = await uploadFile(api, `corrupt.${extension}`, Buffer.from('not a valid spreadsheet', 'utf8'));
      expect(response.status()).toBe(422);
      expect((await response.json()).detail).toMatch(/^Extraction failed:/);
    });
  }

  test('image/OCR path accepts the image and handles an unavailable OCR runtime safely @regression', async ({ api }) => {
    const { response, body } = await uploadFile(api, 'phone-image.png', fixture('phone-image.png'));
    await expectStatus(response, 200);
    expect(body.ok).toBe(true);
    expect(body.parser === 'OCR_IMAGE' || body.parser.startsWith('IMAGE_OCR_UNAVAILABLE:')).toBe(true);
    if (body.parser.startsWith('IMAGE_OCR_UNAVAILABLE:')) expect(body.phone_candidates).toBe(0);
  });

  test('mixed valid and malformed rows retain only the candidates found by the source regex @phone-extraction @regression', async ({ api }) => {
    const { response, body } = await uploadFile(api, 'mixed-records.csv', fixture('mixed-records.csv'));
    await expectStatus(response, 200);
    expect(body.rows_scanned).toBe(5);
    expect(body.phone_candidates).toBe(1);
    expect(body.sample).toEqual(['+14155550132']);
  });

  test('ISO and slash-separated calendar dates are not treated as phone candidates @phone-extraction @regression', async ({ api }) => {
    const { response, body } = await uploadFile(api, 'date-only.log', 'CDR event 2025-01-15 at 2026/10/01.');
    await expectStatus(response, 200);
    expect(body.phone_candidates).toBe(0);
  });

  test('short extensions and malformed text do not become phone candidates @phone-extraction @regression', async ({ api }) => {
    const { response, body } = await uploadFile(api, 'invalid-records.csv', fixture('invalid-records.csv'));
    await expectStatus(response, 200);
    expect(body.phone_candidates).toBe(0);
  });

  test('duplicate representations are extracted as candidates; ingestion itself does not claim to deduplicate @dedupe @regression', async ({ api }) => {
    const { response, body } = await uploadFile(api, 'duplicate-records.csv', fixture('duplicate-records.csv'));
    await expectStatus(response, 200);
    expect(body.phone_candidates).toBe(3);
    expect(body.sample).toHaveLength(3);
  });

  test('international strings are candidates but normalization remains a separate US-only step @phone-extraction @regression', async ({ api }) => {
    const { response, body } = await uploadFile(api, 'international-numbers.csv', fixture('international-numbers.csv'));
    await expectStatus(response, 200);
    expect(body.phone_candidates).toBe(3);
    expect(body.sample).toEqual(['+442079460000', '+61255501000', '+33123456789']);
  });

  test('an empty file is accepted as a zero-row upload @regression', async ({ api }) => {
    const { response, body } = await uploadFile(api, 'empty.csv', Buffer.alloc(0));
    await expectStatus(response, 200);
    expect(body).toMatchObject({ ok: true, rows_scanned: 0, phone_candidates: 0, parser: 'TEXT_TABLE' });
  });

  test('text without a phone is accepted with zero candidates @regression', async ({ api }) => {
    const { response, body } = await uploadFile(api, 'notes.txt', 'A synthetic note without a telephone number.');
    await expectStatus(response, 200);
    expect(body.phone_candidates).toBe(0);
    expect(body.parser).toBe('TEXT_TABLE');
  });

  test('malformed JSON is returned as a controlled 422 extraction error @regression', async ({ api }) => {
    const { response } = await uploadFile(api, 'malformed.json', '{ "phone": ');
    expect(response.status()).toBe(422);
    expect((await response.json()).detail).toMatch(/^Extraction failed:/);
  });

  test('corrupt ZIP is rejected without crashing the API @security @regression', async ({ api }) => {
    const { response } = await uploadFile(api, 'corrupt.zip', fixture('corrupt.zip'));
    expect(response.status()).toBe(422);
    expect((await response.json()).detail).toMatch(/^Extraction failed:/);
    expect((await api.get('/health')).status()).toBe(200);
  });

  test('path traversal ZIP member is treated as archive content, not an extraction destination @security @regression', async ({ api }) => {
    const { response, body } = await uploadFile(api, 'path-traversal.zip', fixture('path-traversal.zip'));
    await expectStatus(response, 200);
    expect(body.parser).toBe('ARCHIVE');
    expect(body.phone_candidates).toBe(1);
  });

  test('path-like multipart filename is treated as ordinary upload metadata @security @regression', async ({ api }) => {
    const { response, body } = await uploadFile(api, '../../qa-outside.csv', fixture('phones.csv'));
    await expectStatus(response, 200);
    expect(body.file_name).toBe('../../qa-outside.csv');
    expect(body.phone_candidates).toBe(3);
  });

  test('unknown extension and MIME are accepted by universal-upload contract @security @regression', async ({ api }) => {
    const { response, body } = await uploadFile(api, 'evidence.unlisted', 'Unknown extension evidence +1 415 555 0132', 'application/x-unlisted-test');
    await expectStatus(response, 200);
    expect(body.extension).toBe('unlisted');
    expect(body.parser).toBe('GENERIC_TEXT');
    expect(body.phone_candidates).toBe(1);
  });

  test('missing multipart file and invalid tenant UUID return 422 @security @regression', async ({ api }) => {
    const missing = await api.post('/api/v2/scrubber/upload', { multipart: { tenant_id: TEST_TENANT_ID } });
    expect(missing.status()).toBe(422);
    const invalidTenant = await api.post('/api/v2/scrubber/upload', {
      multipart: { file: { name: 'phones.csv', mimeType: 'text/csv', buffer: fixture('phones.csv') }, tenant_id: 'tenant OR 1=1' },
    });
    expect(invalidTenant.status()).toBe(422);
    expect((await invalidTenant.json()).detail).toContain('tenant_id must be a GUID');
  });

  test('oversized upload is rejected at the configured MAX_UPLOAD_MB boundary @security @regression', async ({ api }) => {
    const maxUploadMb = Number(process.env.MAX_UPLOAD_MB || 0);
    test.skip(!Number.isFinite(maxUploadMb) || maxUploadMb < 1, 'Set MAX_UPLOAD_MB to run the configured size-limit boundary test.');
    const payload = Buffer.alloc(maxUploadMb * 1024 * 1024 + 1, 0x20);
    const response = await api.post('/api/v2/scrubber/upload', {
      multipart: {
        file: { name: 'over-limit.txt', mimeType: 'text/plain', buffer: payload },
        tenant_id: TEST_TENANT_ID,
      },
      timeout: 60_000,
    });
    expect(response.status()).toBe(413);
    expect((await response.json()).detail).toContain('MAX_UPLOAD_MB');
  });
});
