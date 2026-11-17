import { headers } from 'next/headers';
import QRCode from 'qrcode';
import {
  channelLabel,
  formatDate,
  formatDateTime,
  formatSize,
  noteLines,
} from '@/lib/format';
import { channelsOf, releasesOfChannel } from '@/lib/releases';
import { emptyManifest } from '@/lib/shared.mjs';
import { readManifest, storeMode } from '@/lib/store';
import type { Manifest, Release } from '@/lib/store';
import { DownloadIcon, Logo, StarMark } from './ui';

export const dynamic = 'force-dynamic';

type Query = Record<string, string | string[] | undefined>;

const first = (value: string | string[] | undefined) => (Array.isArray(value) ? value[0] : value);

export default async function HomePage({ searchParams }: { searchParams: Promise<Query> }) {
  const query = await searchParams;

  let manifest: Manifest = emptyManifest();
  let loadFailed = false;
  try {
    manifest = await readManifest();
  } catch (error) {
    console.error('[manifest] read failed:', (error as Error).name);
    loadFailed = true;
  }

  const channels = channelsOf(manifest);
  const { channel, releases } = releasesOfChannel(manifest, first(query.kenh));
  const [latest, ...older] = releases;
  const qrSvg = await buildQr();

  return (
    <div className="page">
      <header className="topbar">
        <Logo className="logo" />
        <span className="topbar-note">Ứng dụng cho máy cầm tay</span>
      </header>

      <main>
        {channels.length > 1 && (
          <nav className="channels" aria-label="Kênh phát hành">
            {channels.map((c) => (
              <a
                key={c}
                className="channel"
                href={`/?kenh=${encodeURIComponent(c)}`}
                aria-current={c === channel ? 'page' : undefined}
              >
                {channelLabel(c)}
              </a>
            ))}
          </nav>
        )}

        <div className="lead">
          {latest ? (
            <LatestCard release={latest} showChannel={channels.length > 1 || latest.channel !== 'production'} />
          ) : (
            <EmptyCard loadFailed={loadFailed} />
          )}

          <aside className="card qr-card" aria-labelledby="qr-title">
            <div className="qr" dangerouslySetInnerHTML={{ __html: qrSvg }} />
            <div>
              <h2 id="qr-title" className="card-title">
                Mở trên máy cầm tay
              </h2>
              <p className="muted">Dùng máy cầm tay quét mã này để mở trang tải.</p>
            </div>
          </aside>
        </div>

        <section className="card" aria-labelledby="steps-title">
          <h2 id="steps-title" className="card-title">
            Cách cài đặt
          </h2>
          <ol className="steps">
            <li>
              <span className="step-no" aria-hidden="true">1</span>
              <p>
                Bấm <strong>Tải về máy</strong>. Nếu trình duyệt cảnh báo file có thể gây hại, chọn{' '}
                <strong>Vẫn tải xuống</strong>.
              </p>
            </li>
            <li>
              <span className="step-no" aria-hidden="true">2</span>
              <p>
                Mở file vừa tải từ thanh thông báo. Lần đầu máy sẽ hỏi quyền cài đặt: bật{' '}
                <strong>Cho phép từ nguồn này</strong> rồi quay lại.
              </p>
            </li>
            <li>
              <span className="step-no" aria-hidden="true">3</span>
              <p>
                Bấm <strong>Cài đặt</strong>, hoặc <strong>Cập nhật</strong> nếu máy đã có bản cũ. Dữ liệu và
                đăng nhập trên máy được giữ nguyên.
              </p>
            </li>
          </ol>
          <p className="muted steps-help">
            Máy báo &ldquo;Ứng dụng chưa được cài đặt&rdquo;? Liên hệ bộ phận IT để được hỗ trợ.
          </p>
        </section>

        {older.length > 0 && (
          <section className="card" aria-labelledby="history-title">
            <h2 id="history-title" className="card-title">
              Phiên bản trước
            </h2>
            <ul className="history">
              {older.map((release) => (
                <HistoryRow key={release.id} release={release} />
              ))}
            </ul>
          </section>
        )}
      </main>

      <footer className="footer">
        <span>CASLA · Trang tải ứng dụng nội bộ</span>
        {latest && <span>Cập nhật {formatDateTime(manifest.updatedAt)}</span>}
      </footer>
    </div>
  );
}

function LatestCard({ release, showChannel }: { release: Release; showChannel: boolean }) {
  const notes = noteLines(release.notes);
  return (
    <section className="hero" aria-labelledby="hero-title">
      <StarMark className="hero-star" />
      <p className="eyebrow">
        Phiên bản mới nhất
        {showChannel && <span className="badge">{channelLabel(release.channel)}</span>}
      </p>
      <h1 id="hero-title" className="version">
        <span className="visually-hidden">Ứng dụng CASLA, phiên bản </span>
        {release.versionName}
        <span className="build">build {release.versionCode}</span>
      </h1>
      <p className="hero-meta">
        Phát hành {formatDateTime(release.publishedAt)}
        <span aria-hidden="true"> · </span>
        {formatSize(release.size)}
      </p>

      <a className="cta" href={`/api/download/${encodeURIComponent(release.id)}`}>
        <DownloadIcon />
        Tải về máy
      </a>
      <p className="file-name">{release.fileName}</p>

      {notes.length > 0 && (
        <div className="notes">
          <h2>Có gì mới</h2>
          <ul>
            {notes.map((line, index) => (
              <li key={index}>{line}</li>
            ))}
          </ul>
        </div>
      )}

      <details className="verify">
        <summary>Thông tin kiểm tra file</summary>
        <dl>
          <dt>SHA-256</dt>
          <dd className="mono">{release.sha256}</dd>
          {release.packageId && (
            <>
              <dt>Gói ứng dụng</dt>
              <dd className="mono">{release.packageId}</dd>
            </>
          )}
          <dt>Kiểu build</dt>
          <dd>
            {release.channel} · {release.mode}
          </dd>
        </dl>
      </details>
    </section>
  );
}

function EmptyCard({ loadFailed }: { loadFailed: boolean }) {
  const unconfigured = storeMode() === 'unconfigured';
  return (
    <section className="hero hero-empty" aria-labelledby="hero-title">
      <StarMark className="hero-star" />
      <h1 id="hero-title" className="empty-title">
        {loadFailed ? 'Chưa đọc được danh sách phiên bản' : 'Chưa có bản phát hành nào'}
      </h1>
      <p className="hero-meta">
        {loadFailed
          ? 'Máy chủ lưu trữ đang không phản hồi. Vui lòng tải lại trang sau ít phút.'
          : unconfigured
            ? 'Trang chưa được nối với Blob store: thiếu biến BLOB_READ_WRITE_TOKEN trên Vercel.'
            : 'Bản cài đặt sẽ xuất hiện ở đây ngay sau lần phát hành đầu tiên.'}
      </p>
    </section>
  );
}

function HistoryRow({ release }: { release: Release }) {
  const notes = noteLines(release.notes);
  return (
    <li className="history-row">
      <div className="history-main">
        <p className="history-version">
          {release.versionName}
          <span className="build">build {release.versionCode}</span>
        </p>
        <p className="muted">
          {formatDate(release.publishedAt)}
          <span aria-hidden="true"> · </span>
          {formatSize(release.size)}
        </p>
        {notes.length > 0 && (
          <details className="history-notes">
            <summary>Ghi chú</summary>
            <ul>
              {notes.map((line, index) => (
                <li key={index}>{line}</li>
              ))}
            </ul>
          </details>
        )}
      </div>
      <a
        className="ghost"
        href={`/api/download/${encodeURIComponent(release.id)}`}
        aria-label={`Tải phiên bản ${release.versionName} build ${release.versionCode}`}
      >
        <DownloadIcon />
        Tải
      </a>
    </li>
  );
}

/** QR dẫn về chính trang này. */
async function buildQr(): Promise<string> {
  const h = await headers();
  const host = h.get('x-forwarded-host') ?? h.get('host') ?? 'localhost:3000';
  const proto = h.get('x-forwarded-proto') ?? (host.startsWith('localhost') ? 'http' : 'https');
  return QRCode.toString(`${proto}://${host}/`, {
    type: 'svg',
    margin: 1,
    errorCorrectionLevel: 'M',
    color: { dark: '#0E1730', light: '#FFFFFF' },
  });
}
