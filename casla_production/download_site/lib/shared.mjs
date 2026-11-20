// Dùng chung cho trang web (Next.js) và scripts/release.mjs, để hai bên luôn
// đọc/ghi cùng một manifest.
import { BlobNotFoundError, get, head } from '@vercel/blob';

/** Thư mục kho thử cục bộ (khi không có BLOB_READ_WRITE_TOKEN). */
export const LOCAL_STORE_DIR = '.local-store';

export const APK_CONTENT_TYPE = 'application/vnd.android.package-archive';

/** Danh sách phiên bản, nằm trong cùng store với các file APK. */
export const MANIFEST_PATHNAME = 'meta/manifest.json';

/**
 * Kiểu Blob store đã tạo trên Vercel. Mặc định public: máy tải thẳng file từ CDN.
 * @param {Record<string, string | undefined>} [env]
 * @returns {'private' | 'public'}
 */
export function blobAccess(env = process.env) {
  return (env.BLOB_ACCESS ?? '').trim().toLowerCase() === 'private' ? 'private' : 'public';
}

/**
 * @typedef {object} Release
 * @property {string} id            Mã duy nhất, dùng trong link tải.
 * @property {string} channel       production | staging | dev | ...
 * @property {string} mode          debug | release
 * @property {string} versionName   Ví dụ 1.0.0
 * @property {number} versionCode   Số build (versionCode của Android)
 * @property {string} [packageId]   applicationId đọc từ APK, nếu có aapt
 * @property {string} fileName      Tên file khi tải về
 * @property {number} size          Byte
 * @property {string} sha256
 * @property {string} publishedAt   ISO 8601
 * @property {string} [notes]       Ghi chú phát hành, mỗi dòng một ý
 * @property {string} pathname      Đường dẫn trong store
 * @property {string} [downloadUrl] Chỉ có với store public
 *
 * @typedef {object} Manifest
 * @property {1} schema
 * @property {string} updatedAt
 * @property {Release[]} releases
 */

/** @returns {Manifest} */
export function emptyManifest() {
  return { schema: 1, updatedAt: new Date(0).toISOString(), releases: [] };
}

/**
 * Chuẩn hóa dữ liệu đọc về: bỏ mục hỏng, xếp mới nhất lên đầu.
 * @param {unknown} raw
 * @returns {Manifest}
 */
export function normalizeManifest(raw) {
  const base = emptyManifest();
  if (!raw || typeof raw !== 'object') return base;
  const input = /** @type {{ updatedAt?: unknown, releases?: unknown }} */ (raw);
  const list = Array.isArray(input.releases) ? input.releases : [];
  /** @type {Release[]} */
  const releases = list.filter(
    (r) =>
      r &&
      typeof r === 'object' &&
      typeof r.id === 'string' &&
      typeof r.channel === 'string' &&
      typeof r.versionName === 'string' &&
      Number.isFinite(r.versionCode) &&
      typeof r.pathname === 'string' &&
      typeof r.publishedAt === 'string',
  );
  releases.sort((a, b) => b.publishedAt.localeCompare(a.publishedAt));
  return {
    schema: 1,
    updatedAt: typeof input.updatedAt === 'string' ? input.updatedAt : base.updatedAt,
    releases,
  };
}

/**
 * Đọc manifest mới nhất từ Blob, kèm ETag để ghi lại có điều kiện.
 *
 * Store public: CDN của Blob giữ bản cũ của manifest lâu hơn max-age, nên đọc
 * thẳng URL sẽ ra danh sách cũ. `head()` hỏi API (luôn mới) lấy ETag, rồi gắn
 * ETag vào URL để mỗi phiên bản manifest có một khóa cache riêng.
 * @param {'private' | 'public'} [access]
 * @returns {Promise<{ manifest: Manifest, etag: string | null }>}
 */
export async function fetchBlobManifest(access = blobAccess()) {
  if (access === 'private') {
    const result = await get(MANIFEST_PATHNAME, { access, useCache: false });
    if (!result || result.statusCode !== 200) return { manifest: emptyManifest(), etag: null };
    return { manifest: normalizeManifest(await new Response(result.stream).json()), etag: result.blob.etag };
  }

  let meta;
  try {
    meta = await head(MANIFEST_PATHNAME);
  } catch (error) {
    if (error instanceof BlobNotFoundError) return { manifest: emptyManifest(), etag: null };
    throw error;
  }
  const response = await fetch(`${meta.url}?v=${encodeURIComponent(meta.etag)}`, { cache: 'no-store' });
  if (!response.ok) throw new Error(`Manifest HTTP ${response.status}`);
  return { manifest: normalizeManifest(await response.json()), etag: meta.etag };
}
