// Deterministic release with a changelog larger than a pipe buffer.
globalThis.fetch = (async (input: string | URL | Request) => {
  const url = String(input);
  if (url.endsWith('/releases/latest')) {
    return Response.json({ tag_name: 'v99.0.0', published_at: '2026-01-01', html_url: 'https://example.com/release' });
  }
  if (url.endsWith('/CHANGELOG.md')) {
    return new Response('## [99.0.0]\n' + '- Release detail\n'.repeat(1000000) + 'END-OF-CHANGELOG\n');
  }
  throw new Error('Unexpected test request: ' + url);
}) as typeof fetch;
