import { readFile } from 'node:fs/promises';
import path from 'node:path';

export interface ReleaseMetadata {
  downloadUrl: string;
  versionLabel?: string;
}

const fallbackDownloadUrl = 'https://github.com/LRDOC/notchi/releases/latest';
const appcastPath = path.resolve(process.cwd(), 'public/appcast.xml');

export async function getReleaseMetadata(): Promise<ReleaseMetadata> {
  try {
    const appcast = await readFile(appcastPath, 'utf8');
    const itemMatch = appcast.match(/<item>([\s\S]*?)<\/item>/);

    if (!itemMatch) {
      return { downloadUrl: fallbackDownloadUrl };
    }

    const item = itemMatch[1];
    const versionMatch = item.match(/<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/);
    const enclosureUrlMatch = item.match(/<enclosure[^>]*url="([^"]+)"/);

    if (!versionMatch?.[1] || !enclosureUrlMatch?.[1]) {
      return { downloadUrl: fallbackDownloadUrl };
    }

    return {
      downloadUrl: enclosureUrlMatch[1],
      versionLabel: `v${versionMatch[1]} · Requires macOS Sequoia`,
    };
  } catch {
    return { downloadUrl: fallbackDownloadUrl };
  }
}
