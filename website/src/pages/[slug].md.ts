import { readdir, readFile } from 'node:fs/promises';
import path from 'node:path';
import type { APIRoute, GetStaticPaths } from 'astro';

const releaseNotesDir = path.resolve(process.cwd(), '../docs/release-notes');

export const getStaticPaths: GetStaticPaths = async () => {
  const entries = await readdir(releaseNotesDir, { withFileTypes: true });

  return entries
    .filter((entry) => entry.isFile() && entry.name.endsWith('.md'))
    .map((entry) => {
      const version = entry.name.replace(/\.md$/, '');
      return {
        params: {
          slug: `Notchi-${version}`,
        },
      };
    });
};

export const GET: APIRoute = async ({ params }) => {
  const slug = params.slug;

  if (!slug?.startsWith('Notchi-')) {
    return new Response('Not found', { status: 404 });
  }

  const version = slug.slice('Notchi-'.length);
  const releaseNotesPath = path.join(releaseNotesDir, `${version}.md`);

  try {
    const content = await readFile(releaseNotesPath, 'utf8');

    return new Response(content, {
      headers: {
        'Content-Type': 'text/markdown; charset=utf-8',
      },
    });
  } catch {
    return new Response('Not found', { status: 404 });
  }
};
