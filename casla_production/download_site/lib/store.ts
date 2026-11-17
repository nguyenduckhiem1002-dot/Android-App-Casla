import { createReadStream, promises as fs } from 'node:fs';
import path from 'node:path';
import { Readable } from 'node:stream';
import { get, issueSignedToken, presignUrl } from '@vercel/blob';
import {
  APK_CONTENT_TYPE,
  LOCAL_STORE_DIR,
  MANIFEST_PATHNAME,
  blobAccess,
  emptyManifest,
  normalizeManifest,
} from './shared.mjs';
import type { Manifest, Release } from './shared.mjs';

export type { Manifest, Release };

/**
 * blob        : có token, đọc từ Vercel Blob.
 * local       : chạy ở máy dev không có token, đọc `.local-store/` (do
 *               `release.mjs --local` ghi) để xem thử trang.
 * unconfigured: đang chạy trên Vercel nhưng chưa nối Blob store.
 */
export type StoreMode = 'blob' | 'local' | 'unconfigured';

export function storeMode(): StoreMode {
  if (process.env.BLOB_READ_WRITE_TOKEN) return 'blob';
  if (process.env.VERCEL) return 'unconfigured';
  return 'local';
}

// Kho cục bộ chỉ dùng khi dev: không cho Turbopack gom cả project vào bản build.
const localRoot = () => path.join(/*turbopackIgnore: true*/ process.cwd(), LOCAL_STORE_DIR);

const MANIFEST_TTL_MS = 15_000;
let cached: { at: number; manifest: Manifest } | null = null;

export async function readManifest(): Promise<Manifest> {
  if (cached && Date.now() - cached.at < MANIFEST_TTL_MS) return cached.manifest;
  const manifest = await loadManifest();
  cached = { at: Date.now(), manifest };
  return manifest;
}

async function loadManifest(): Promise<Manifest> {
  const mode = storeMode();
  if (mode === 'unconfigured') return emptyManifest();

  if (mode === 'local') {
    try {
      const file = path.join(/*turbopackIgnore: true*/ localRoot(), 'manifest.json');
      return normalizeManifest(JSON.parse(await fs.readFile(file, 'utf8')));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return emptyManifest();
      throw error;
    }
  }

  const result = await get(MANIFEST_PATHNAME, { access: blobAccess(), useCache: false });
  if (!result || result.statusCode !== 200) return emptyManifest();
  return normalizeManifest(await new Response(result.stream).json());
}

export type DownloadTarget =
  | { kind: 'redirect'; url: string }
  | { kind: 'stream'; body: ReadableStream<Uint8Array>; size: number | null };

const PRESIGN_TTL_MS = 10 * 60 * 1000;

/** Nơi lấy file APK của một bản phát hành; `null` nếu file không còn. */
export async function resolveDownload(release: Release): Promise<DownloadTarget | null> {
  const mode = storeMode();
  if (mode === 'unconfigured') return null;

  if (mode === 'local') {
    const root = localRoot();
    const file = path.resolve(/*turbopackIgnore: true*/ root, release.pathname);
    if (!file.startsWith(root + path.sep)) return null;
    try {
      const stat = await fs.stat(file);
      const body = Readable.toWeb(createReadStream(file)) as ReadableStream<Uint8Array>;
      return { kind: 'stream', body, size: stat.size };
    } catch {
      return null;
    }
  }

  // Store public: máy tải thẳng từ CDN của Blob.
  if (blobAccess() === 'public') {
    return release.downloadUrl ? { kind: 'redirect', url: release.downloadUrl } : null;
  }

  // Store private: cấp link ký tạm 10 phút, vẫn tải thẳng từ CDN.
  try {
    const validUntil = Date.now() + PRESIGN_TTL_MS;
    const signed = await issueSignedToken({
      pathname: release.pathname,
      operations: ['get'],
      validUntil,
    });
    const { presignedUrl } = await presignUrl(signed, {
      operation: 'get',
      pathname: release.pathname,
      access: 'private',
      validUntil,
    });
    return { kind: 'redirect', url: presignedUrl };
  } catch (error) {
    // Không ký được link thì chuyển file qua chính function này (chậm hơn).
    console.error('[download] presign failed, streaming instead:', (error as Error).name);
    const result = await get(release.pathname, { access: 'private' });
    if (!result || result.statusCode !== 200) return null;
    return { kind: 'stream', body: result.stream, size: result.blob.size };
  }
}

export { APK_CONTENT_TYPE };
