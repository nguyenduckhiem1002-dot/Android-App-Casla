const TIME_ZONE = 'Asia/Ho_Chi_Minh';

const dateTime = new Intl.DateTimeFormat('vi-VN', {
  timeZone: TIME_ZONE,
  day: '2-digit',
  month: '2-digit',
  year: 'numeric',
  hour: '2-digit',
  minute: '2-digit',
  hour12: false,
});

const dateOnly = new Intl.DateTimeFormat('vi-VN', {
  timeZone: TIME_ZONE,
  day: '2-digit',
  month: '2-digit',
  year: 'numeric',
});

export function formatDateTime(iso: string): string {
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? '' : dateTime.format(date);
}

export function formatDate(iso: string): string {
  const date = new Date(iso);
  return Number.isNaN(date.getTime()) ? '' : dateOnly.format(date);
}

export function formatSize(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '';
  const mb = bytes / (1024 * 1024);
  const digits = mb >= 100 ? 0 : 1;
  return `${mb.toLocaleString('vi-VN', { maximumFractionDigits: digits, minimumFractionDigits: digits })} MB`;
}

const CHANNEL_LABELS: Record<string, string> = {
  production: 'Chính thức',
  staging: 'Thử nghiệm',
  dev: 'Phát triển',
};

export function channelLabel(channel: string): string {
  return CHANNEL_LABELS[channel] ?? channel;
}

/** Thứ tự hiện kênh: chính thức trước, còn lại theo bảng chữ cái. */
export function sortChannels(channels: string[]): string[] {
  const order = ['production', 'staging', 'dev'];
  const rank = (c: string) => (order.includes(c) ? order.indexOf(c) : order.length);
  return [...channels].sort((a, b) => rank(a) - rank(b) || a.localeCompare(b));
}

export function noteLines(notes: string | undefined): string[] {
  return (notes ?? '')
    .split(/\r?\n/)
    .map((line) => line.replace(/^\s*[-*•]\s*/, '').trim())
    .filter(Boolean);
}
