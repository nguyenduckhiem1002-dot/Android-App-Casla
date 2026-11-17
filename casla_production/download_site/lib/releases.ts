import { sortChannels } from './format';
import type { Manifest, Release } from './shared.mjs';

export function channelsOf(manifest: Manifest): string[] {
  return sortChannels([...new Set(manifest.releases.map((r) => r.channel))]);
}

/** Các bản của một kênh, mới nhất trước. Kênh không hợp lệ thì lấy kênh đầu. */
export function releasesOfChannel(
  manifest: Manifest,
  requested: string | null | undefined,
): { channel: string | null; releases: Release[] } {
  const channels = channelsOf(manifest);
  if (channels.length === 0) return { channel: null, releases: [] };
  const channel = requested && channels.includes(requested) ? requested : channels[0];
  return { channel, releases: manifest.releases.filter((r) => r.channel === channel) };
}
