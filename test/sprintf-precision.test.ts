import { describe, expect, test } from 'bun:test';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { sprintf } = require('sprintf-js');

describe('patched sprintf-js numeric precision (GHSA-hp3w-g68c-fv3c)', () => {
  for (const conversion of ['e', 'f', 'g']) {
    for (const precision of ['101', '1000000000', '999999999999999999999999999999']) {
      test(`${conversion} clamps precision ${precision}`, () => {
        const output = sprintf(`%.${precision}${conversion}`, 1.25);
        expect(typeof output).toBe('string');
        expect(output.length).toBeLessThanOrEqual(110);
        expect(output).toBe(sprintf(`%.100${conversion}`, 1.25));
      });
    }
  }
  test('zero precision g cannot abort formatting', () => {
    expect(sprintf('%.0g', 1.25)).toBe('1');
  });
  test('ordinary numeric and argparse string formatting is preserved', () => {
    expect(sprintf('%.2f', 1.25)).toBe('1.25');
    expect(sprintf('%.0f', 1.25)).toBe('1');
    expect(sprintf('%.2e', 1.25)).toBe('1.25e+0');
    expect(sprintf('%.2g', 1.25)).toBe('1.3');
    expect(sprintf('%s: error: %s', 'tool', 'invalid option')).toBe('tool: error: invalid option');
  });
});
