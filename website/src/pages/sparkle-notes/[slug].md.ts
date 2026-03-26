import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import type { APIRoute, GetStaticPaths } from 'astro';

const signedReleaseNotesDir = path.resolve(process.cwd(), 'release-notes-signed');

export const getStaticPaths: GetStaticPaths = async () => {
  const entries = await readdir(signedReleaseNotesDir, { withFileTypes: true });

  return entries
    .filter((entry) => entry.isFile() && entry.name.endsWith('.md'))
    .map((entry) => ({
      params: {
        slug: entry.name.replace(/\.md$/, ''),
      },
    }));
};

export const GET: APIRoute = async ({ params }) => {
  const slug = params.slug;

  if (!slug?.startsWith('Notchi-')) {
    return new Response('Not found', { status: 404 });
  }

  try {
    const content = await readFile(path.join(signedReleaseNotesDir, `${slug}.md`), 'utf8');

    return new Response(content, {
      headers: {
        'Content-Type': 'text/markdown; charset=utf-8',
      },
    });
  } catch {
    return new Response('Not found', { status: 404 });
  }
};
