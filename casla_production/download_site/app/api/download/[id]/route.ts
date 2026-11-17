import { NextRequest, NextResponse } from 'next/server';
import { releasesOfChannel } from '@/lib/releases';
import { APK_CONTENT_TYPE, readManifest, resolveDownload } from '@/lib/store';

export const dynamic = 'force-dynamic';
// Chỉ cần khi phải chuyển file qua function (không ký được link).
export const maxDuration = 300;

function plain(message: string, status: number) {
  return new NextResponse(message, {
    status,
    headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' },
  });
}

/**
 * /api/download/<id>            tải đúng một bản
 * /api/download/latest          bản mới nhất của kênh chính
 * /api/download/latest?kenh=x   bản mới nhất của kênh x
 */
export async function GET(request: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  try {
    const manifest = await readManifest();
    const release =
      id === 'latest'
        ? releasesOfChannel(manifest, request.nextUrl.searchParams.get('kenh')).releases[0]
        : manifest.releases.find((r) => r.id === id);
    if (!release) return plain('Không tìm thấy phiên bản này.', 404);

    const target = await resolveDownload(release);
    if (!target) return plain('File của phiên bản này không còn trên máy chủ.', 404);

    if (target.kind === 'redirect') {
      const response = NextResponse.redirect(target.url, 302);
      response.headers.set('Cache-Control', 'no-store');
      return response;
    }

    const headers = new Headers({
      'Content-Type': APK_CONTENT_TYPE,
      'Content-Disposition': `attachment; filename="${release.fileName.replace(/[^\w.+-]/g, '_')}"`,
      'Cache-Control': 'private, no-store',
    });
    if (target.size) headers.set('Content-Length', String(target.size));
    return new NextResponse(target.body, { status: 200, headers });
  } catch (error) {
    console.error('[download] failed:', (error as Error).name);
    return plain('Không lấy được file. Vui lòng thử lại sau ít phút.', 502);
  }
}
