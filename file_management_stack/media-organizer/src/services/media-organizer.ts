// =============================================================================
// media-organizer.ts
// =============================================================================
// Single-file standalone media organizer for Hono.
// Mount in index.ts:
//
//   import { createMediaOrganizer, MEDIA_CONFIG } from "./media-organizer";
//   const organizer = createMediaOrganizer();
//   app.route("/", organizer);
//
// Environment variables (set in .env or docker-compose):
//   MEDIA_SOURCE_DIR   — mounted source directory  (default: /media/input)
//   MEDIA_OUTPUT_DIR   — mounted output directory  (default: /media/processed)
//   MEDIA_DUMP_DIR     — dump directory for stale folders (default: /media/input/.dump)
//   LOG_DIR            — log file directory         (default: ./logs)
// =============================================================================

import { Hono } from "hono";
import fs from "fs";
import path from "path";
import crypto from "crypto";

// ─────────────────────────────────────────────────────────────────────────────
// 1. CONFIG — reads from environment, validated at startup
// ─────────────────────────────────────────────────────────────────────────────

export const MEDIA_CONFIG = {
  sourceDir: process.env.MEDIA_SOURCE_DIR ?? "/media/input",
  outputDir: process.env.MEDIA_OUTPUT_DIR ?? "/media/processed",
  dumpDir:   process.env.MEDIA_DUMP_DIR   ?? "/media/input/.dump",
  logDir:    process.env.LOG_DIR          ?? "./logs",
} as const;

// ─────────────────────────────────────────────────────────────────────────────
// 2. TYPES
// ─────────────────────────────────────────────────────────────────────────────

type MediaType    = "image" | "video" | "both";
type Granularity  = "day" | "week" | "month" | "related";
type MoveResult   = "moved" | "skipped" | "dry";

interface MediaFile {
  fullPath:  string;
  filename:  string;
  ext:       string;
  type:      "image" | "video";
  size:      number;
  baseName:  string;
  dateStamp: string | null;   // YYYYMMDD
  hourStamp: string | null;   // HH
}

interface GroupSummary {
  groupKey:   string;
  dir:        string;
  fileCount:  number;
  sizeBytes:  number;
  sizeHuman:  string;
  files:      string[];
}

interface DuplicateInfo {
  hash:      string;
  original:  string;
  duplicate: string;
}

interface OperationResult {
  operation:         string;
  dryRun:            boolean;
  sourceDir:         string;
  outputDir:         string;
  groups:            GroupSummary[];
  duplicates:        DuplicateInfo[];
  emptyDirsRemoved:  number;
  totalFiles:        number;
  totalBytes:        number;
  totalBytesHuman:   string;
  errors:            string[];
  dumpReport?:       DumpReport;
}

interface MountCheck {
  sourceDir: { path: string; exists: boolean; readable: boolean };
  outputDir: { path: string; exists: boolean; writable: boolean };
  dumpDir:   { path: string; exists: boolean };
  healthy:   boolean;
  warnings:  string[];
}

interface DumpReport {
  dumpDir:         string;
  foldersArchived: string[];
  filesExtracted:  number;
  errors:          string[];
}

interface ScanReport {
  sourceDir:      string;
  totalFiles:     number;
  images:         number;
  videos:         number;
  totalBytes:     number;
  totalBytesHuman: string;
  duplicateGroups: number;
  duplicateFiles:  number;
  emptyDirs:       number;
  subDirs:         string[];
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. CONSTANTS
// ─────────────────────────────────────────────────────────────────────────────

const IMAGE_EXTS = new Set([".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".tiff", ".heic"]);
const VIDEO_EXTS = new Set([".mp4", ".mkv", ".mov", ".avi", ".flv", ".wmv", ".m4v", ".3gp"]);
const DUMP_DIRNAME = ".dump";

// ─────────────────────────────────────────────────────────────────────────────
// 4. LOGGER  (file + console, no external deps)
// ─────────────────────────────────────────────────────────────────────────────

function ensureLogDir(): void {
  fs.mkdirSync(MEDIA_CONFIG.logDir, { recursive: true });
}

function logLine(level: string, message: string): void {
  const line = `${new Date().toISOString().replace("T", " ").slice(0, 19)} [${level}] ${message}`;
  console.log(line);
  try {
    ensureLogDir();
    fs.appendFileSync(path.join(MEDIA_CONFIG.logDir, "combined.log"), line + "\n");
    if (level === "ERROR" || level === "WARN") {
      fs.appendFileSync(path.join(MEDIA_CONFIG.logDir, "error.log"), line + "\n");
    }
  } catch { /* non-fatal */ }
}

const log = {
  info:  (msg: string) => logLine("INFO",  msg),
  warn:  (msg: string) => logLine("WARN",  msg),
  error: (msg: string) => logLine("ERROR", msg),
  debug: (msg: string) => logLine("DEBUG", msg),
};

// ─────────────────────────────────────────────────────────────────────────────
// 5. FILE UTILITIES
// ─────────────────────────────────────────────────────────────────────────────

function walkDir(dir: string, skipDump = true): string[] {
  const results: string[] = [];
  if (!fs.existsSync(dir)) return results;
  let entries: fs.Dirent[];
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); }
  catch { return results; }
  for (const e of entries) {
    if (skipDump && e.name === DUMP_DIRNAME) continue;
    const full = path.join(dir, e.name);
    if (e.isDirectory()) results.push(...walkDir(full, skipDump));
    else if (e.isFile()) results.push(full);
  }
  return results;
}

function getSubDirs(dir: string, skipDump = true): string[] {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true })
    .filter(e => e.isDirectory() && (!skipDump || e.name !== DUMP_DIRNAME))
    .map(e => path.join(dir, e.name));
}

function extractDateStamp(filename: string): string | null {
  const m = filename.match(/^(\d{8})_/);
  return m ? m[1] : null;
}

function extractHourStamp(filename: string): string | null {
  const m = filename.match(/^\d{8}_(\d{2})\d{4}/);
  return m ? m[1] : null;
}

function extractBaseTimestamp(filename: string): string {
  const noExt = path.parse(filename).name;
  const m = noExt.match(/^(\d{8}_\d{6})/);
  return m ? m[1] : noExt.replace(/_\d+$/, "");
}

function getWeekKey(dateStamp: string): string {
  const y = parseInt(dateStamp.slice(0, 4));
  const mo = parseInt(dateStamp.slice(4, 6)) - 1;
  const d = parseInt(dateStamp.slice(6, 8));
  const dt = new Date(y, mo, d);
  const soy = new Date(y, 0, 1);
  const week = Math.ceil(((dt.getTime() - soy.getTime()) / 86400000 + soy.getDay() + 1) / 7);
  return `${y}_W${String(week).padStart(2, "0")}`;
}

function getMonthKey(dateStamp: string): string {
  return dateStamp.slice(0, 6);
}

function hashFile(filePath: string): string {
  try {
    const buf = fs.readFileSync(filePath);
    return crypto.createHash("md5").update(buf).digest("hex");
  } catch {
    return `nohash_${filePath}`;
  }
}

function humanReadable(bytes: number): string {
  if (bytes > 1_073_741_824) return `${(bytes / 1_073_741_824).toFixed(2)}GB`;
  if (bytes > 1_048_576)     return `${(bytes / 1_048_576).toFixed(2)}MB`;
  if (bytes > 1_024)         return `${(bytes / 1_024).toFixed(2)}KB`;
  return `${bytes}B`;
}

function safeMkdir(dir: string, dryRun: boolean): void {
  if (!dryRun) fs.mkdirSync(dir, { recursive: true });
}

function safeMove(src: string, dst: string, dryRun: boolean): MoveResult {
  if (dryRun) return "dry";
  if (!fs.existsSync(src)) return "skipped";
  if (fs.existsSync(dst))  return "skipped";
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.renameSync(src, dst);
  return "moved";
}

function removeEmptyDirs(dir: string, dryRun: boolean): number {
  let count = 0;
  if (!fs.existsSync(dir)) return count;
  let entries: fs.Dirent[];
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); }
  catch { return count; }
  for (const e of entries) {
    if (e.name === DUMP_DIRNAME) continue;
    if (e.isDirectory()) count += removeEmptyDirs(path.join(dir, e.name), dryRun);
  }
  try {
    const remaining = fs.readdirSync(dir).filter(n => n !== DUMP_DIRNAME);
    if (remaining.length === 0 && dir !== MEDIA_CONFIG.sourceDir) {
      if (!dryRun) fs.rmdirSync(dir);
      count++;
    }
  } catch { /* non-fatal */ }
  return count;
}

function collectMedia(dir: string, mediaType: MediaType): MediaFile[] {
  const files = walkDir(dir);
  return files.reduce<MediaFile[]>((acc, fullPath) => {
    const filename = path.basename(fullPath);
    const ext = path.extname(filename).toLowerCase();
    const isImage = IMAGE_EXTS.has(ext);
    const isVideo = VIDEO_EXTS.has(ext);
    if (!isImage && !isVideo) return acc;
    if (mediaType === "image" && !isImage) return acc;
    if (mediaType === "video" && !isVideo) return acc;
    let size = 0;
    try { size = fs.statSync(fullPath).size; } catch { /* skip */ }
    acc.push({
      fullPath, filename, ext,
      type:      isImage ? "image" : "video",
      size,
      baseName:  extractBaseTimestamp(filename),
      dateStamp: extractDateStamp(filename),
      hourStamp: extractHourStamp(filename),
    });
    return acc;
  }, []);
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. DUPLICATE DETECTION (shared, reused across all operations)
// ─────────────────────────────────────────────────────────────────────────────

function buildHashMap(files: MediaFile[]): Map<string, string[]> {
  const map = new Map<string, string[]>();
  for (const f of files) {
    const h = hashFile(f.fullPath);
    if (!map.has(h)) map.set(h, []);
    map.get(h)!.push(f.fullPath);
  }
  return map;
}

function getDuplicateHashes(hashMap: Map<string, string[]>): Set<string> {
  const dupSet = new Set<string>();
  for (const [hash, paths] of hashMap.entries()) {
    if (paths.length > 1) dupSet.add(hash);
  }
  return dupSet;
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. DUMP OPERATION
// Extracts all media out of any sub-folder in sourceDir,
// moves those now-empty sub-folders to .dump,
// and returns all media as a flat set ready for grouping.
// ─────────────────────────────────────────────────────────────────────────────

function runDump(dryRun: boolean): DumpReport {
  const report: DumpReport = {
    dumpDir:         MEDIA_CONFIG.dumpDir,
    foldersArchived: [],
    filesExtracted:  0,
    errors:          [],
  };

  const subDirs = getSubDirs(MEDIA_CONFIG.sourceDir, true);
  if (subDirs.length === 0) {
    log.info("[dump] No subdirectories to process");
    return report;
  }

  safeMkdir(MEDIA_CONFIG.dumpDir, dryRun);

  for (const subDir of subDirs) {
    const dirName = path.basename(subDir);

    // 7a. Extract all media files out of this subdirectory (recursive)
    const mediaFiles = walkDir(subDir, false);
    for (const filePath of mediaFiles) {
      const ext = path.extname(filePath).toLowerCase();
      if (!IMAGE_EXTS.has(ext) && !VIDEO_EXTS.has(ext)) continue;
      const dst = path.join(MEDIA_CONFIG.sourceDir, path.basename(filePath));
      // handle filename collision by appending a counter
      let finalDst = dst;
      let counter = 1;
      while (fs.existsSync(finalDst) && !dryRun) {
        const p = path.parse(dst);
        finalDst = path.join(p.dir, `${p.name}_${counter}${p.ext}`);
        counter++;
      }
      const result = safeMove(filePath, finalDst, dryRun);
      log.info(`[dump] EXTRACT ${path.relative(MEDIA_CONFIG.sourceDir, filePath)} -> ${path.basename(finalDst)} [${result}]`);
      report.filesExtracted++;
    }

    // 7b. Move the now-emptied folder to .dump
    const dumpTarget = path.join(MEDIA_CONFIG.dumpDir, `${dirName}_${Date.now()}`);
    if (!dryRun) {
      try {
        fs.renameSync(subDir, dumpTarget);
        log.info(`[dump] ARCHIVED ${dirName} -> .dump/${path.basename(dumpTarget)}`);
        report.foldersArchived.push(dumpTarget);
      } catch (e) {
        const msg = `Failed to archive ${subDir}: ${String(e)}`;
        report.errors.push(msg);
        log.error(msg);
      }
    } else {
      log.info(`[dump] DRY archive ${dirName} -> .dump/${path.basename(dumpTarget)}`);
      report.foldersArchived.push(dumpTarget);
    }
  }

  return report;
}

// ─────────────────────────────────────────────────────────────────────────────
// 8. CORE GROUPING ENGINE (shared by all organize operations)
// ─────────────────────────────────────────────────────────────────────────────

function moveGroups(
  groupedFiles: Map<string, MediaFile[]>,
  outputDir:    string,
  hashMap:      Map<string, string[]>,
  dupSet:       Set<string>,
  fileToHash:   Map<string, string>,
  dryRun:       boolean,
  tag:          string,
): { groups: GroupSummary[]; duplicates: DuplicateInfo[]; errors: string[] } {
  const groups: GroupSummary[]   = [];
  const duplicates: DuplicateInfo[] = [];
  const errors: string[]         = [];
  const hashOriginal              = new Map<string, string>();

  for (const [groupKey, files] of groupedFiles.entries()) {
    if (files.length === 0) continue;

    const groupSize = files.reduce((s, f) => s + f.size, 0);
    const sizeSuffix = groupSize > 1_073_741_824
      ? `${(groupSize / 1_073_741_824).toFixed(1)}gb`
      : `${Math.round(groupSize / 1_048_576)}mb`;

    const dirName  = `${groupKey}__${files.length}_${sizeSuffix}`;
    const groupDir = path.join(outputDir, dirName);
    safeMkdir(groupDir, dryRun);

    const movedFiles: string[] = [];

    for (const file of files) {
      const hash     = fileToHash.get(file.fullPath) ?? "";
      const isDup    = hash && dupSet.has(hash);
      const isFirst  = hash && !hashOriginal.has(hash);

      if (isDup && hash) {
        if (isFirst) {
          hashOriginal.set(hash, file.fullPath);
        } else {
          const dupDir = path.join(groupDir, ".duplicates");
          safeMkdir(dupDir, dryRun);
          const dst    = path.join(dupDir, file.filename);
          const result = safeMove(file.fullPath, dst, dryRun);
          duplicates.push({ hash, original: hashOriginal.get(hash)!, duplicate: file.fullPath });
          log.info(`[${tag}] DUP  ${file.filename} -> .duplicates/ [${result}]`);
          movedFiles.push(`${file.filename} [DUP]`);
          continue;
        }
      }

      const dst = path.join(groupDir, file.filename);
      try {
        const result = safeMove(file.fullPath, dst, dryRun);
        log.info(`[${tag}] MOVE ${file.filename} -> ${dirName}/ [${result}]`);
        movedFiles.push(file.filename);
      } catch (e) {
        const msg = `Failed to move ${file.fullPath}: ${String(e)}`;
        errors.push(msg);
        log.error(msg);
      }
    }

    groups.push({ groupKey, dir: groupDir, fileCount: files.length, sizeBytes: groupSize, sizeHuman: humanReadable(groupSize), files: movedFiles });
    log.info(`[${tag}] GROUP ${groupKey} | ${files.length} files (${humanReadable(groupSize)})`);
  }

  return { groups, duplicates, errors };
}

// ─────────────────────────────────────────────────────────────────────────────
// 9. INDIVIDUAL OPERATIONS
// ─────────────────────────────────────────────────────────────────────────────

// ── 9a. Mount / health check ──────────────────────────────────────────────────

function checkMounts(): MountCheck {
  const warnings: string[] = [];

  const srcExists   = fs.existsSync(MEDIA_CONFIG.sourceDir);
  const srcReadable = srcExists ? (() => { try { fs.readdirSync(MEDIA_CONFIG.sourceDir); return true; } catch { return false; } })() : false;
  const outExists   = fs.existsSync(MEDIA_CONFIG.outputDir);
  const outWritable = outExists ? (() => { try { fs.accessSync(MEDIA_CONFIG.outputDir, fs.constants.W_OK); return true; } catch { return false; } })() : false;
  const dumpExists  = fs.existsSync(MEDIA_CONFIG.dumpDir);

  if (!srcExists)   warnings.push(`sourceDir does not exist: ${MEDIA_CONFIG.sourceDir}`);
  if (!srcReadable) warnings.push(`sourceDir is not readable: ${MEDIA_CONFIG.sourceDir}`);
  if (!outExists)   warnings.push(`outputDir does not exist: ${MEDIA_CONFIG.outputDir} (will be created on first run)`);
  if (!outWritable && outExists) warnings.push(`outputDir is not writable: ${MEDIA_CONFIG.outputDir}`);
  if (!dumpExists)  warnings.push(`dumpDir does not yet exist: ${MEDIA_CONFIG.dumpDir} (created automatically)`);

  return {
    sourceDir: { path: MEDIA_CONFIG.sourceDir, exists: srcExists, readable: srcReadable },
    outputDir: { path: MEDIA_CONFIG.outputDir, exists: outExists, writable: outWritable },
    dumpDir:   { path: MEDIA_CONFIG.dumpDir,   exists: dumpExists },
    healthy:   srcExists && srcReadable,
    warnings,
  };
}

// ── 9b. Scan ─────────────────────────────────────────────────────────────────

function scanSource(mediaType: MediaType): ScanReport {
  const files   = collectMedia(MEDIA_CONFIG.sourceDir, mediaType);
  const hashMap = buildHashMap(files);
  const dupSet  = getDuplicateHashes(hashMap);

  let dupFiles = 0;
  for (const [, paths] of hashMap.entries()) {
    if (paths.length > 1) dupFiles += paths.length - 1;
  }

  // count empty dirs
  let emptyDirs = 0;
  const subDirs = getSubDirs(MEDIA_CONFIG.sourceDir);
  const countEmpty = (dir: string): void => {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    for (const e of entries) {
      if (e.isDirectory()) countEmpty(path.join(dir, e.name));
    }
    if (entries.length === 0) emptyDirs++;
  };
  subDirs.forEach(d => { try { countEmpty(d); } catch { /* skip */ } });

  return {
    sourceDir:       MEDIA_CONFIG.sourceDir,
    totalFiles:      files.length,
    images:          files.filter(f => f.type === "image").length,
    videos:          files.filter(f => f.type === "video").length,
    totalBytes:      files.reduce((s, f) => s + f.size, 0),
    totalBytesHuman: humanReadable(files.reduce((s, f) => s + f.size, 0)),
    duplicateGroups: dupSet.size,
    duplicateFiles:  dupFiles,
    emptyDirs,
    subDirs:         subDirs.map(d => path.basename(d)),
  };
}

// ── 9c. Group operation (shared entry for all group-by variants) ──────────────

function runGroupOperation(
  mediaType:    MediaType,
  granularity:  "filename" | "day" | "week" | "month" | "hour" | "related" | "flatten" | "separate",
  dryRun:       boolean,
  runDumpFirst: boolean,
): OperationResult {
  const tag = `${granularity}:${mediaType}`;
  log.info(`[${tag}] Starting | dryRun=${dryRun} | dump=${runDumpFirst}`);

  // ── Step 1: optional dump (extract from subdirs, archive stale folders)
  let dumpReport: DumpReport | undefined;
  if (runDumpFirst) {
    dumpReport = runDump(dryRun);
    log.info(`[${tag}] Dump complete | extracted=${dumpReport.filesExtracted} archived=${dumpReport.foldersArchived.length}`);
  }

  // ── Step 2: collect media from (now-flat) sourceDir
  const files = collectMedia(MEDIA_CONFIG.sourceDir, mediaType);
  log.info(`[${tag}] Collected ${files.length} files`);

  if (files.length === 0) {
    return {
      operation: tag, dryRun,
      sourceDir: MEDIA_CONFIG.sourceDir, outputDir: MEDIA_CONFIG.outputDir,
      groups: [], duplicates: [], emptyDirsRemoved: 0,
      totalFiles: 0, totalBytes: 0, totalBytesHuman: "0B", errors: [], dumpReport,
    };
  }

  // ── Step 3: build hash map once — reused in grouping engine
  const hashMap   = buildHashMap(files);
  const dupSet    = getDuplicateHashes(hashMap);
  const fileToHash = new Map<string, string>();
  for (const [hash, paths] of hashMap.entries()) {
    for (const p of paths) fileToHash.set(p, hash);
  }

  log.info(`[${tag}] Hashed ${files.length} files, ${dupSet.size} duplicate group(s)`);

  // ── Step 4: build grouping map based on granularity
  const grouped = new Map<string, MediaFile[]>();
  const push = (key: string, f: MediaFile) => {
    if (!grouped.has(key)) grouped.set(key, []);
    grouped.get(key)!.push(f);
  };

  if (granularity === "filename") {
    for (const f of files) push(f.baseName || "undated", f);

  } else if (granularity === "day") {
    for (const f of files) push(f.dateStamp ?? "undated", f);

  } else if (granularity === "week") {
    for (const f of files) push(f.dateStamp ? getWeekKey(f.dateStamp) : "undated", f);

  } else if (granularity === "month") {
    for (const f of files) push(f.dateStamp ? getMonthKey(f.dateStamp) : "undated", f);

  } else if (granularity === "hour") {
    for (const f of files) {
      const key = (f.dateStamp && f.hourStamp) ? `${f.dateStamp}_${f.hourStamp}` : "undated";
      push(key, f);
    }

  } else if (granularity === "related") {
    // Only groups that have BOTH an image AND a video
    const byHour = new Map<string, { images: MediaFile[]; videos: MediaFile[] }>();
    for (const f of files) {
      if (!f.dateStamp || !f.hourStamp) continue;
      const k = `${f.dateStamp}_${f.hourStamp}`;
      if (!byHour.has(k)) byHour.set(k, { images: [], videos: [] });
      if (f.type === "image") byHour.get(k)!.images.push(f);
      else                    byHour.get(k)!.videos.push(f);
    }
    for (const [k, g] of byHour.entries()) {
      if (g.images.length > 0 && g.videos.length > 0) {
        for (const f of [...g.images, ...g.videos]) push(k, f);
      }
    }

  } else if (granularity === "flatten") {
    for (const f of files) push("flat", f);

  } else if (granularity === "separate") {
    for (const f of files) push(f.type === "image" ? "images" : "videos", f);
  }

  // ── Step 5: move files
  const outputDir = MEDIA_CONFIG.outputDir;
  safeMkdir(outputDir, dryRun);

  const { groups, duplicates, errors } = moveGroups(
    grouped, outputDir, hashMap, dupSet, fileToHash, dryRun, tag
  );

  // ── Step 6: clean up empty dirs
  const emptyDirsRemoved = removeEmptyDirs(MEDIA_CONFIG.sourceDir, dryRun);

  const totalBytes = files.reduce((s, f) => s + f.size, 0);

  log.info(`[${tag}] Done | groups=${groups.length} dupes=${duplicates.length} empty-dirs-removed=${emptyDirsRemoved}`);

  return {
    operation: tag,
    dryRun,
    sourceDir: MEDIA_CONFIG.sourceDir,
    outputDir,
    groups,
    duplicates,
    emptyDirsRemoved,
    totalFiles: files.length,
    totalBytes,
    totalBytesHuman: humanReadable(totalBytes),
    errors,
    dumpReport,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// 10. GUIDE DATA
// ─────────────────────────────────────────────────────────────────────────────

function buildGuide(mounts: MountCheck) {
  return {
    title:   "Media Organizer — API Reference",
    version: "2.0.0",
    mounts: {
      sourceDir: mounts.sourceDir,
      outputDir: mounts.outputDir,
      dumpDir:   mounts.dumpDir,
      healthy:   mounts.healthy,
      warnings:  mounts.warnings,
    },
    howItWorks: [
      "1. All operations read from MEDIA_SOURCE_DIR and write to MEDIA_OUTPUT_DIR.",
      "2. No body is required — directories are pre-mounted via environment variables.",
      "3. Routes are split into /dry/... (preview, no moves) and /live/... (real moves).",
      "4. Before grouping, a dump step extracts media from any subdirectory, archives those folders to .dump/, then works on a flat source.",
      "5. Duplicate files are detected by MD5 hash and moved to .duplicates/ inside each group folder.",
      "6. Empty directories in sourceDir are removed after every operation.",
    ],
    envVars: {
      MEDIA_SOURCE_DIR: `Current: ${MEDIA_CONFIG.sourceDir}`,
      MEDIA_OUTPUT_DIR: `Current: ${MEDIA_CONFIG.outputDir}`,
      MEDIA_DUMP_DIR:   `Current: ${MEDIA_CONFIG.dumpDir}`,
      LOG_DIR:          `Current: ${MEDIA_CONFIG.logDir}`,
    },
    routeGroups: {
      system: {
        description: "Health, mounts, calendar, logs",
        routes: [
          { method: "GET", path: "/health",            description: "Server + mount health check" },
          { method: "GET", path: "/calendar",          description: "Current date keys (dayKey, weekKey, monthKey)" },
          { method: "GET", path: "/logs/recent",       description: "Tail combined.log  ?lines=N (default 100)" },
          { method: "GET", path: "/logs/errors",       description: "Tail error.log     ?lines=N (default 100)" },
          { method: "GET", path: "/guide",             description: "This document" },
        ],
      },
      scan: {
        description: "Read-only — never moves files",
        routes: [
          { method: "GET", path: "/scan/image",        description: "Inventory images in sourceDir" },
          { method: "GET", path: "/scan/video",        description: "Inventory videos in sourceDir" },
          { method: "GET", path: "/scan/both",         description: "Inventory all media in sourceDir" },
        ],
      },
      dump: {
        description: "Extract media from subdirs, archive folders to .dump/",
        routes: [
          { method: "POST", path: "/dry/dump",         description: "Preview dump operation" },
          { method: "POST", path: "/live/dump",        description: "Run dump (real move)" },
        ],
      },
      organize: {
        description: "Group media. All routes support /dry/... and /live/...",
        mediaTypes:  ["image", "video", "both"],
        groupings:   ["filename", "day", "week", "month", "hour", "related", "flatten", "separate"],
        pattern:     "/:dryness/organize/:mediaType/:grouping",
        examples: [
          { path: "/dry/organize/both/day",      description: "Preview grouping both by day" },
          { path: "/live/organize/image/month",  description: "Group images by month (real)" },
          { path: "/live/organize/video/week",   description: "Group videos by week (real)" },
          { path: "/dry/organize/both/related",  description: "Preview related image+video pairs" },
          { path: "/live/organize/both/flatten", description: "Flatten all media to single dir" },
          { path: "/live/organize/both/separate",description: "Split into images/ and videos/" },
          { path: "/live/organize/both/filename",description: "Group by filename timestamp" },
          { path: "/live/organize/image/hour",   description: "Group images by hour" },
        ],
      },
    },
    outputFolderPatterns: {
      filename:  "{YYYYMMDD_HHMMSS}__{count}_{size}",
      day:       "{YYYYMMDD}__{count}_{size}",
      week:      "{YYYY_WNN}__{count}_{size}",
      month:     "{YYYYMM}__{count}_{size}",
      hour:      "{YYYYMMDD_HH}__{count}_{size}",
      related:   "{YYYYMMDD_HH}__{count}_{size}  (only mixed image+video groups)",
      flatten:   "flat__{count}_{size}",
      separate:  "images__{count}_{size}  /  videos__{count}_{size}",
    },
    recommendedWorkflow: [
      "GET  /health                          — confirm mounts are ready",
      "GET  /scan/both                       — understand what you have",
      "POST /dry/dump                        — preview folder extraction",
      "POST /live/dump                       — extract & archive subdirs",
      "POST /dry/organize/both/day           — preview day grouping",
      "POST /live/organize/both/day          — commit grouping",
      "GET  /logs/recent?lines=50            — confirm moves in log",
    ],
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// 11. HONO APP FACTORY
// ─────────────────────────────────────────────────────────────────────────────

export function createMediaOrganizer(): Hono {
  const app = new Hono();

  // ── Startup mount validation ────────────────────────────────────────────────
  const mounts = checkMounts();
  if (!mounts.healthy) {
    mounts.warnings.forEach(w => log.warn(`[startup] ${w}`));
  } else {
    log.info(`[startup] Mounts OK | src=${MEDIA_CONFIG.sourceDir} out=${MEDIA_CONFIG.outputDir}`);
  }

  // ── Request logging ─────────────────────────────────────────────────────────
  app.use("*", async (c, next) => {
    const start = Date.now();
    await next();
    log.info(`${c.req.method} ${c.req.path} ${c.res.status} ${Date.now() - start}ms`);
  });

  // ── Shared mount guard (applied to all /dry and /live routes) ───────────────
  const requireHealthyMounts = async (c: any, next: any) => {
    const m = checkMounts();
    if (!m.healthy) {
      return c.json({ error: "Source directory not ready", mounts: m }, 503);
    }
    await next();
  };

  // ─────────────────────────────────────────────────────────────────────────────
  // SYSTEM ROUTES
  // ─────────────────────────────────────────────────────────────────────────────

  app.get("/health", (c) => {
    const m = checkMounts();
    return c.json({ status: m.healthy ? "ok" : "degraded", ...m, timestamp: new Date().toISOString() }, m.healthy ? 200 : 503);
  });

  app.get("/calendar", (c) => {
    const now = new Date();
    const soy = new Date(now.getFullYear(), 0, 1);
    const week = Math.ceil(((now.getTime() - soy.getTime()) / 86400000 + soy.getDay() + 1) / 7);
    return c.json({
      now:         now.toISOString(),
      date:        now.toISOString().slice(0, 10),
      year:        now.getFullYear(),
      month:       now.getMonth() + 1,
      monthPadded: String(now.getMonth() + 1).padStart(2, "0"),
      day:         now.getDate(),
      dayPadded:   String(now.getDate()).padStart(2, "0"),
      weekOfYear:  week,
      weekKey:     `${now.getFullYear()}_W${String(week).padStart(2, "0")}`,
      monthKey:    `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, "0")}`,
      dayKey:      `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, "0")}${String(now.getDate()).padStart(2, "0")}`,
      timezone:    Intl.DateTimeFormat().resolvedOptions().timeZone,
    });
  });

  app.get("/logs/recent", (c) => {
    const lines = Math.min(parseInt(c.req.query("lines") ?? "100", 10), 500);
    const file  = path.join(MEDIA_CONFIG.logDir, "combined.log");
    if (!fs.existsSync(file)) return c.json({ lines: 0, log: [] });
    const content = fs.readFileSync(file, "utf-8").trim().split("\n").slice(-lines);
    return c.json({ lines: content.length, log: content });
  });

  app.get("/logs/errors", (c) => {
    const lines = Math.min(parseInt(c.req.query("lines") ?? "100", 10), 500);
    const file  = path.join(MEDIA_CONFIG.logDir, "error.log");
    if (!fs.existsSync(file)) return c.json({ lines: 0, log: [] });
    const content = fs.readFileSync(file, "utf-8").trim().split("\n").slice(-lines);
    return c.json({ lines: content.length, log: content });
  });

  app.get("/guide", (c) => {
    return c.json(buildGuide(checkMounts()));
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // SCAN ROUTES  (read-only, no body, no mount guard needed — just reports)
  // ─────────────────────────────────────────────────────────────────────────────

  const scanHandler = (mediaType: MediaType) => (c: any) => {
    try {
      const report = scanSource(mediaType);
      return c.json(report);
    } catch (e) {
      return c.json({ error: String(e) }, 500);
    }
  };

  app.get("/scan/image", scanHandler("image"));
  app.get("/scan/video", scanHandler("video"));
  app.get("/scan/both",  scanHandler("both"));

  // ─────────────────────────────────────────────────────────────────────────────
  // DUMP ROUTES
  // ─────────────────────────────────────────────────────────────────────────────

  app.post("/dry/dump",  requireHealthyMounts, (c) => {
    try { return c.json(runDump(true)); }
    catch (e) { return c.json({ error: String(e) }, 500); }
  });

  app.post("/live/dump", requireHealthyMounts, (c) => {
    try { return c.json(runDump(false)); }
    catch (e) { return c.json({ error: String(e) }, 500); }
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // ORGANIZE ROUTES
  // Pattern: /:dryness/organize/:mediaType/:grouping
  //   dryness   → dry | live
  //   mediaType → image | video | both
  //   grouping  → filename | day | week | month | hour | related | flatten | separate
  //
  // Each route runs dump first (extracts media from sub-folders) then groups.
  // ─────────────────────────────────────────────────────────────────────────────

  const VALID_MEDIA: Set<string>    = new Set(["image", "video", "both"]);
  const VALID_GROUP: Set<string>    = new Set(["filename", "day", "week", "month", "hour", "related", "flatten", "separate"]);

  const organizeHandler = (dryRun: boolean) => async (c: any) => {
    const mediaType  = c.req.param("mediaType")  as string;
    const grouping   = c.req.param("grouping")   as string;

    if (!VALID_MEDIA.has(mediaType)) {
      return c.json({ error: `Invalid mediaType '${mediaType}'. Valid: image | video | both` }, 400);
    }
    if (!VALID_GROUP.has(grouping)) {
      return c.json({ error: `Invalid grouping '${grouping}'. Valid: ${[...VALID_GROUP].join(" | ")}` }, 400);
    }

    try {
      const result = runGroupOperation(
        mediaType as MediaType,
        grouping  as any,
        dryRun,
        true,  // always run dump before organizing
      );
      return c.json(result);
    } catch (e) {
      log.error(`[organize] Unhandled: ${String(e)}`);
      return c.json({ error: String(e) }, 500);
    }
  };

  app.post("/dry/organize/:mediaType/:grouping",  requireHealthyMounts, organizeHandler(true));
  app.post("/live/organize/:mediaType/:grouping", requireHealthyMounts, organizeHandler(false));

  // ─────────────────────────────────────────────────────────────────────────────
  // 404 & ERROR FALLBACK
  // ─────────────────────────────────────────────────────────────────────────────

  app.notFound((c) =>
    c.json({ error: "Not found", hint: "GET /guide for all available routes" }, 404)
  );

  app.onError((err, c) => {
    log.error(`Unhandled: ${err.message}`);
    return c.json({ error: "Internal server error", detail: err.message }, 500);
  });

  return app;
}
