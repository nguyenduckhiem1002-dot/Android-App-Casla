#!/usr/bin/env node
// Phát hành một bản APK lên trang tải: build → tải file lên Vercel Blob →
// cập nhật manifest. Trang web đọc manifest nên bản mới hiện ngay, không cần
// deploy lại. Xem README.md cùng thư mục.
import { execFile, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream, existsSync, openAsBlob, promises as fs, readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs, promisify } from 'node:util';
import { BlobPreconditionFailedError, del, put } from '@vercel/blob';
import {
  APK_CONTENT_TYPE,
  LOCAL_STORE_DIR,
  MANIFEST_PATHNAME,
  blobAccess,
  fetchBlobManifest,
  normalizeManifest,
} from '../lib/shared.mjs';

const siteDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const flutterRoot = path.resolve(siteDir, '..');
const localStore = path.join(siteDir, LOCAL_STORE_DIR);

const HELP = `
Phát hành APK CASLA lên trang tải.

  tool\\publish_release.cmd [tùy chọn]
  node download_site/scripts/release.mjs [tùy chọn]

Tùy chọn build
  --flavor <tên>        staging | production | dev         (mặc định: staging)
  --mode <kiểu>         debug | release
  --env-file <file>     File dart-define, tính từ gốc project
  --target-platform <p> Ví dụ android-arm64; "all" = mọi kiến trúc
  --build-name <x.y.z>  Ghi đè versionName của pubspec.yaml
  --build-number <n>    Ghi đè versionCode của pubspec.yaml
  --bump                Tự tăng versionCode (xem dưới)
  --skip-build          Không build, dùng APK đã có ở build/app/outputs/flutter-apk
  --apk <file>          Phát hành đúng file APK này (không build)

Mặc định theo flavor (khớp docs/PROJECT_HARNESS.md):
  staging     release · .env.qas · android-arm64 · tự tăng versionCode
  production  debug   · .env
  dev         debug   · .env
Tự tăng versionCode = số lớn nhất trong (pubspec, bản đã phát hành gần nhất + 1,
APK đang có trong thư mục build + 1), để máy đã cài bản cũ cập nhật đè được.

Tùy chọn phát hành
  --notes "<nội dung>"  Ghi chú phát hành; dùng \\n để xuống dòng
  --notes-file <file>   Đọc ghi chú từ file văn bản (UTF-8), mỗi dòng một ý
  --channel <tên>       Kênh hiện trên trang                (mặc định: = flavor)
  --keep <n>            Số bản giữ lại mỗi kênh, 0 = giữ hết (mặc định: 5)
  --local               Ghi vào ${LOCAL_STORE_DIR}/ thay vì Vercel Blob, để xem thử
  --dry-run             Chỉ in kế hoạch, không build lại và không tải lên
  --help

Quản lý
  --list                Liệt kê các bản đang có trên trang
  --remove <id>         Gỡ một bản khỏi trang và xóa file của nó (id lấy từ --list)

Token Blob đọc từ download_site/.env.local (BLOB_READ_WRITE_TOKEN).
`;

class ReleaseError extends Error {}

// Khớp bảng "Lệnh chuẩn" trong docs/PROJECT_HARNESS.md.
const PRESETS = {
  staging: { mode: 'release', envFile: '.env.qas', targetPlatform: 'android-arm64', bump: true },
  production: { mode: 'debug', envFile: '.env', targetPlatform: null, bump: false },
  dev: { mode: 'debug', envFile: '.env', targetPlatform: null, bump: false },
};

const log = (message = '') => console.log(message);
const step = (message) => console.log(`\n> ${message}`);

async function main() {
  const { values } = parseArgs({
    options: {
      flavor: { type: 'string', default: 'staging' },
      mode: { type: 'string' },
      'env-file': { type: 'string' },
      'target-platform': { type: 'string' },
      'build-name': { type: 'string' },
      'build-number': { type: 'string' },
      bump: { type: 'boolean', default: false },
      'skip-build': { type: 'boolean', default: false },
      apk: { type: 'string' },
      notes: { type: 'string' },
      'notes-file': { type: 'string' },
      channel: { type: 'string' },
      keep: { type: 'string', default: '5' },
      local: { type: 'boolean', default: false },
      'dry-run': { type: 'boolean', default: false },
      list: { type: 'boolean', default: false },
      remove: { type: 'string' },
      help: { type: 'boolean', default: false },
    },
  });

  if (values.help) {
    log(HELP);
    return;
  }

  if (values.list || values.remove) {
    loadSiteEnv();
    const storage = values.local ? localStorage() : blobStorage();
    log(`Kho lưu: ${storage.label}`);
    if (values.remove) await removeRelease(storage, values.remove);
    else listReleases(await storage.readManifest());
    return;
  }

  const flavor = values.flavor;
  const preset = PRESETS[flavor];
  if (!preset) {
    throw new ReleaseError(`--flavor phải là staging, production hoặc dev (đang là "${flavor}").`);
  }
  const mode = values.mode ?? preset.mode;
  const envFile = values['env-file'] ?? preset.envFile;
  const targetPlatform = values['target-platform'] ?? preset.targetPlatform;
  if (!['debug', 'release'].includes(mode)) {
    throw new ReleaseError(`--mode phải là debug hoặc release (đang là "${mode}").`);
  }
  const channel = slug(values.channel ?? flavor);
  const keep = Number.parseInt(values.keep, 10);
  if (!Number.isInteger(keep) || keep < 0) throw new ReleaseError('--keep phải là số nguyên từ 0.');
  if (values.bump && values['build-number']) {
    throw new ReleaseError('Chỉ dùng một trong hai: --bump hoặc --build-number.');
  }
  const bump = !values['build-number'] && (values.bump || preset.bump);

  loadSiteEnv();
  const storage = values.local ? localStorage() : blobStorage();
  log(`Kho lưu: ${storage.label}`);

  // ----- Phiên bản -----
  const manifest = await storage.readManifest();
  const pubspec = await readPubspecVersion();
  const lastCode = Math.max(0, ...manifest.releases.filter((r) => r.channel === channel).map((r) => r.versionCode));

  let buildNumber = values['build-number'] ? Number.parseInt(values['build-number'], 10) : null;
  if (values['build-number'] && !(buildNumber > 0)) throw new ReleaseError('--build-number phải là số nguyên dương.');
  const buildName = values['build-name'] ?? null;

  // ----- Build -----
  const building = !values.apk && !values['skip-build'];
  const apkPath = values.apk
    ? path.resolve(process.cwd(), values.apk)
    : path.join(flutterRoot, 'build', 'app', 'outputs', 'flutter-apk', `app-${flavor}-${mode}.apk`);

  if (building && bump) {
    // APK còn trong thư mục build thường là bản đang cài trên máy người dùng.
    const previous = existsSync(apkPath) ? await readApkBadge(apkPath) : null;
    buildNumber = Math.max(pubspec.code, lastCode + 1, (previous?.versionCode ?? 0) + 1);
  }

  if (building && !values['dry-run']) {
    await buildApk({ flavor, mode, envFile, targetPlatform, buildName, buildNumber, apkPath });
  } else if (!building && (buildName || buildNumber)) {
    log('Lưu ý: không build nên --build-name/--build-number/--bump chỉ dùng khi không đọc được số phiên bản từ APK.');
  }

  if (values['dry-run'] && building) {
    const platform = targetPlatform && targetPlatform !== 'all' ? `, ${targetPlatform}` : '';
    const number = buildNumber ? `, build ${buildNumber}` : '';
    log(`\n[dry-run] Sẽ build ${flavor} ${mode} (${envFile}${platform}${number})`);
    log(`[dry-run] rồi phát hành ${rel(apkPath)} lên kênh "${channel}".`);
    return;
  }
  if (!existsSync(apkPath)) throw new ReleaseError(`Không thấy file APK: ${apkPath}`);

  // ----- Thông tin file -----
  step('Đọc thông tin APK');
  const badge = await readApkBadge(apkPath);
  const versionName = badge?.versionName ?? buildName ?? pubspec.name;
  const versionCode = badge?.versionCode ?? buildNumber ?? pubspec.code;
  const stat = await fs.stat(apkPath);
  const sha256 = await hashFile(apkPath);
  const publishedAt = new Date();
  const stamp = timestamp(publishedAt);
  const fileName = `casla-${channel}-${slug(versionName)}-b${versionCode}.apk`;
  const notes = await readNotes(values);

  /** @type {import('../lib/shared.mjs').Release} */
  const release = {
    id: `${channel}-${slug(versionName)}-b${versionCode}-${stamp}`,
    channel,
    mode,
    versionName,
    versionCode,
    ...(badge?.packageId ? { packageId: badge.packageId } : {}),
    fileName,
    size: stat.size,
    sha256,
    publishedAt: publishedAt.toISOString(),
    ...(notes ? { notes } : {}),
    pathname: `releases/${channel}/${stamp}/${fileName}`,
  };

  log(`  File      : ${rel(apkPath)}`);
  log(`  Phiên bản : ${versionName} (build ${versionCode})${badge ? '' : '  [theo pubspec/tham số, không đọc được từ APK]'}`);
  if (badge?.packageId) log(`  Gói       : ${badge.packageId}`);
  log(`  Kênh      : ${channel} · ${mode}`);
  log(`  Dung lượng: ${megabytes(stat.size)}`);
  log(`  SHA-256   : ${sha256}`);
  if (!building) log(`  Build lúc : ${stat.mtime.toLocaleString('vi-VN')}`);
  if (lastCode > versionCode) {
    log(`  CẢNH BÁO  : build ${versionCode} thấp hơn bản đã phát hành (build ${lastCode}); máy đã cài bản cao hơn sẽ không cập nhật đè được.`);
  }

  // Thêm bản mới, giữ `keep` bản mới nhất của kênh; trả về cả các bản bị loại.
  const plan = (current) => {
    const all = [release, ...current.releases.filter((r) => r.id !== release.id)];
    const drop = keep > 0 ? all.filter((r) => r.channel === channel).slice(keep) : [];
    const dropIds = new Set(drop.map((r) => r.id));
    return {
      drop,
      next: { schema: 1, updatedAt: publishedAt.toISOString(), releases: all.filter((r) => !dropIds.has(r.id)) },
    };
  };

  if (values['dry-run']) {
    const { drop } = plan(manifest);
    log(`\n[dry-run] Sẽ tải lên ${release.pathname}`);
    if (drop.length) log(`[dry-run] Sẽ xóa ${drop.length} bản cũ: ${drop.map((r) => r.id).join(', ')}`);
    return;
  }

  // ----- Tải lên -----
  step(`Tải lên ${megabytes(stat.size)}`);
  const stored = await storage.upload(apkPath, release.pathname, stat.size);
  release.pathname = stored.pathname;
  if (stored.downloadUrl) release.downloadUrl = stored.downloadUrl;

  step('Cập nhật danh sách phiên bản');
  let pruned = [];
  await storage.updateManifest((current) => {
    const { drop, next } = plan(current);
    pruned = drop;
    return next;
  });

  if (pruned.length) {
    step(`Dọn ${pruned.length} bản cũ (giữ ${keep} bản mỗi kênh)`);
    try {
      await storage.remove(pruned.map((r) => r.pathname));
      for (const r of pruned) log(`  đã xóa ${r.id}`);
    } catch (error) {
      log(`  Không xóa được file cũ (${error.message}). Trang vẫn hoạt động bình thường.`);
    }
  }

  log(`\nXong. Đã phát hành ${versionName} (build ${versionCode}) lên kênh "${channel}".`);
  const site = (process.env.SITE_URL ?? '').trim().replace(/\/+$/, '');
  if (values.local) log('Xem thử: chạy `npm run dev` trong download_site rồi mở http://localhost:3000');
  else if (site) log(`Trang tải: ${site}/`);
}

// -------------------------------------------------------------- quản lý

function listReleases(manifest) {
  if (manifest.releases.length === 0) {
    log('Chưa có bản nào trên trang.');
    return;
  }
  log();
  for (const r of manifest.releases) {
    const when = new Date(r.publishedAt).toLocaleString('vi-VN');
    log(`${r.id}`);
    log(`    ${r.channel} · ${r.mode} · ${r.versionName} (build ${r.versionCode}) · ${megabytes(r.size)} · ${when}`);
  }
}

async function removeRelease(storage, id) {
  let target;
  await storage.updateManifest((current) => {
    target = current.releases.find((r) => r.id === id);
    if (!target) {
      throw new ReleaseError(`Không có bản nào mang id "${id}". Xem danh sách: --list`);
    }
    return {
      schema: 1,
      updatedAt: new Date().toISOString(),
      releases: current.releases.filter((r) => r.id !== id),
    };
  });
  await storage.remove([target.pathname]);
  log(`Đã gỡ ${id} khỏi trang và xóa file của nó.`);
}

// ---------------------------------------------------------------- build

async function buildApk({ flavor, mode, envFile, targetPlatform, buildName, buildNumber, apkPath }) {
  const envPath = path.resolve(flutterRoot, envFile);
  if (!existsSync(envPath)) {
    throw new ReleaseError(`Không thấy file dart-define: ${envPath}\nChỉ định bằng --env-file <file>.`);
  }
  const args = ['build', 'apk', '--flavor', flavor, `--${mode}`, `--dart-define-from-file=${envFile}`];
  if (targetPlatform && targetPlatform !== 'all') args.push('--target-platform', targetPlatform);
  if (buildName) args.push('--build-name', buildName);
  if (buildNumber) args.push('--build-number', String(buildNumber));

  step(`flutter ${args.join(' ')}`);
  const startedAt = Date.now();
  const code = await run('flutter', args, flutterRoot);
  if (code !== 0) throw new ReleaseError(`flutter build thất bại (mã thoát ${code}). Chưa có gì được tải lên.`);

  // README của project: APK còn sót từ lần build trước rất dễ bị cài nhầm.
  const stat = await fs.stat(apkPath).catch(() => null);
  if (!stat) throw new ReleaseError(`Build xong nhưng không thấy ${apkPath}`);
  if (stat.mtimeMs < startedAt - 2000) {
    throw new ReleaseError(`${rel(apkPath)} không phải file vừa build (sửa lúc ${stat.mtime.toLocaleString('vi-VN')}).`);
  }
}

function run(command, args, cwd) {
  // Trên Windows `flutter` là file .bat nên phải chạy qua shell.
  const quoted = [command, ...args].map((a) => (/[\s"&|<>^]/.test(a) ? `"${a.replace(/"/g, '\\"')}"` : a));
  return new Promise((resolve, reject) => {
    const child = spawn(quoted.join(' '), { cwd, stdio: 'inherit', shell: true });
    child.on('error', reject);
    child.on('close', (code) => resolve(code ?? 1));
  });
}

// ------------------------------------------------------------ thông tin

async function readPubspecVersion() {
  const text = await fs.readFile(path.join(flutterRoot, 'pubspec.yaml'), 'utf8');
  const match = text.match(/^version:\s*([^\s+]+)(?:\+(\d+))?/m);
  if (!match) throw new ReleaseError('Không đọc được dòng "version:" trong pubspec.yaml.');
  return { name: match[1], code: Number.parseInt(match[2] ?? '1', 10) };
}

/** Đọc versionName/versionCode/applicationId thật trong APK bằng aapt (nếu có Android SDK). */
async function readApkBadge(apkPath) {
  const aapt = findAapt();
  if (!aapt) return null;
  try {
    const { stdout } = await promisify(execFile)(aapt, ['dump', 'badging', apkPath], {
      maxBuffer: 32 * 1024 * 1024,
      windowsHide: true,
    });
    const line = stdout.split(/\r?\n/).find((l) => l.startsWith('package:')) ?? '';
    const pick = (key) => line.match(new RegExp(`${key}='([^']*)'`))?.[1];
    const versionCode = Number.parseInt(pick('versionCode') ?? '', 10);
    const versionName = pick('versionName');
    if (!versionName || !Number.isFinite(versionCode)) return null;
    return { packageId: pick('name'), versionName, versionCode };
  } catch {
    return null;
  }
}

function findAapt() {
  const roots = [process.env.ANDROID_HOME, process.env.ANDROID_SDK_ROOT];
  const propsFile = path.join(flutterRoot, 'android', 'local.properties');
  if (existsSync(propsFile)) {
    const sdkDir = readFileSync(propsFile, 'utf8').match(/^sdk\.dir=(.+)$/m)?.[1]?.trim();
    if (sdkDir) roots.push(sdkDir.replace(/\\\\/g, '\\').replace(/\\:/g, ':'));
  }
  if (process.env.LOCALAPPDATA) roots.push(path.join(process.env.LOCALAPPDATA, 'Android', 'Sdk'));

  const exe = process.platform === 'win32' ? '.exe' : '';
  for (const root of roots.filter(Boolean)) {
    const toolsDir = path.join(root, 'build-tools');
    if (!existsSync(toolsDir)) continue;
    const versions = readdirSync(toolsDir).sort((a, b) => b.localeCompare(a, undefined, { numeric: true }));
    for (const version of versions) {
      for (const name of ['aapt2', 'aapt']) {
        const candidate = path.join(toolsDir, version, name + exe);
        if (existsSync(candidate)) return candidate;
      }
    }
  }
  return null;
}

function hashFile(file) {
  return new Promise((resolve, reject) => {
    const hash = createHash('sha256');
    createReadStream(file)
      .on('data', (chunk) => hash.update(chunk))
      .on('error', reject)
      .on('end', () => resolve(hash.digest('hex')));
  });
}

async function readNotes(values) {
  let text = values.notes ? values.notes.replace(/\\n/g, '\n') : '';
  if (values['notes-file']) {
    const file = path.resolve(process.cwd(), values['notes-file']);
    if (!existsSync(file)) throw new ReleaseError(`Không thấy file ghi chú: ${file}`);
    text = [text, await fs.readFile(file, 'utf8')].filter(Boolean).join('\n');
  }
  return text.replace(/^﻿/, '').trim();
}

// ------------------------------------------------------------- lưu trữ

function loadSiteEnv() {
  const file = path.join(siteDir, '.env.local');
  if (existsSync(file)) process.loadEnvFile(file);
}

function localStorage() {
  const manifestFile = path.join(localStore, 'manifest.json');
  return {
    label: `thử cục bộ (${rel(localStore)})`,
    async readManifest() {
      if (!existsSync(manifestFile)) return normalizeManifest(null);
      return normalizeManifest(JSON.parse(await fs.readFile(manifestFile, 'utf8')));
    },
    async upload(source, pathname) {
      const target = path.join(localStore, pathname);
      await fs.mkdir(path.dirname(target), { recursive: true });
      await fs.copyFile(source, target);
      return { pathname };
    },
    async updateManifest(mutate) {
      const next = mutate(await this.readManifest());
      await fs.mkdir(localStore, { recursive: true });
      await fs.writeFile(manifestFile, JSON.stringify(next, null, 2), 'utf8');
    },
    async remove(pathnames) {
      for (const pathname of pathnames) {
        const target = path.resolve(localStore, pathname);
        if (!target.startsWith(localStore + path.sep)) continue;
        await fs.rm(path.dirname(target), { recursive: true, force: true });
      }
    },
  };
}

function blobStorage() {
  if (!process.env.BLOB_READ_WRITE_TOKEN) {
    throw new ReleaseError(
      [
        'Thiếu BLOB_READ_WRITE_TOKEN.',
        'Tạo download_site/.env.local từ .env.example rồi điền token của Blob store',
        '(Vercel → Storage → store → tab ".env.local"), hoặc thêm --local để thử trên máy.',
      ].join('\n'),
    );
  }
  const access = blobAccess();
  const explain = (error) => {
    const hint = /access|private|public/i.test(error.message ?? '')
      ? `\nKiểm tra BLOB_ACCESS trong .env.local: đang là "${access}", phải khớp kiểu store đã tạo trên Vercel.`
      : '';
    return new ReleaseError(`Vercel Blob báo lỗi: ${error.message}${hint}`);
  };

  return {
    label: `Vercel Blob (${access})`,
    async readManifest() {
      try {
        return (await fetchBlobManifest(access)).manifest;
      } catch (error) {
        throw explain(error);
      }
    },
    async upload(source, pathname, size) {
      try {
        const body = await openAsBlob(source, { type: APK_CONTENT_TYPE });
        let lastShown = -1;
        const result = await put(pathname, body, {
          access,
          multipart: true,
          contentType: APK_CONTENT_TYPE,
          addRandomSuffix: false,
          onUploadProgress: ({ loaded }) => {
            const percent = Math.min(100, Math.floor((loaded / size) * 100));
            if (percent !== lastShown && process.stdout.isTTY) {
              lastShown = percent;
              process.stdout.write(`\r  ${percent}%  (${megabytes(loaded)} / ${megabytes(size)})   `);
            }
          },
        });
        if (process.stdout.isTTY) process.stdout.write('\n');
        return { pathname: result.pathname, downloadUrl: access === 'public' ? result.downloadUrl : undefined };
      } catch (error) {
        if (process.stdout.isTTY) process.stdout.write('\n');
        throw explain(error);
      }
    },
    // Đọc bản mới nhất, sửa, rồi chỉ ghi nếu manifest chưa bị ai đổi (ETag khớp).
    async updateManifest(mutate) {
      for (let attempt = 1; ; attempt += 1) {
        let current;
        try {
          current = await fetchBlobManifest(access);
        } catch (error) {
          throw explain(error);
        }
        const next = mutate(current.manifest);
        try {
          await put(MANIFEST_PATHNAME, JSON.stringify(next, null, 2), {
            access,
            addRandomSuffix: false,
            contentType: 'application/json; charset=utf-8',
            cacheControlMaxAge: 60,
            ...(current.etag ? { ifMatch: current.etag } : { allowOverwrite: true }),
          });
          return;
        } catch (error) {
          if (!(error instanceof BlobPreconditionFailedError)) throw explain(error);
          if (attempt >= 4) {
            throw new ReleaseError('Danh sách phiên bản liên tục bị thay đổi ở nơi khác. Chạy lại lệnh sau ít phút.');
          }
          log('  Danh sách vừa được cập nhật ở nơi khác, đọc lại...');
          await new Promise((resolve) => setTimeout(resolve, 2000));
        }
      }
    },
    async remove(pathnames) {
      if (pathnames.length) await del(pathnames);
    },
  };
}

// --------------------------------------------------------------- tiện ích

function slug(value) {
  return String(value).trim().replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '') || 'x';
}

function timestamp(date) {
  const p = (n) => String(n).padStart(2, '0');
  return (
    `${date.getFullYear()}${p(date.getMonth() + 1)}${p(date.getDate())}` +
    `-${p(date.getHours())}${p(date.getMinutes())}${p(date.getSeconds())}`
  );
}

function megabytes(bytes) {
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function rel(file) {
  const relative = path.relative(flutterRoot, file);
  return relative.startsWith('..') ? file : relative;
}

main().catch((error) => {
  if (error instanceof ReleaseError) {
    console.error(`\nLỖI: ${error.message}`);
  } else if (error?.code === 'ERR_PARSE_ARGS_UNKNOWN_OPTION' || error?.code === 'ERR_PARSE_ARGS_INVALID_OPTION_VALUE') {
    console.error(`\nLỖI: ${error.message}\nXem cách dùng: --help`);
  } else {
    console.error('\nLỖI không lường trước:', error);
  }
  process.exitCode = 1;
});
