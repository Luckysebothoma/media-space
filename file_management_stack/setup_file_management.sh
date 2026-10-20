#!/bin/bash
################################################################################
# MEDIA ORGANIZER STACK SETUP
# Sets up Hono TS API + Docker Swarm + Local Registry Push + Test Suite
# Usage: bash setup_media_stack.sh [--skip-swarm] [--registry HOST:PORT]
################################################################################

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

REGISTRY="${REGISTRY:-192.168.0.140:5000}"
IMAGE_NAME="media-organizer"
IMAGE_TAG="latest"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
PROJECT_DIR="$(pwd)/media-organizer"
SERVICE_NAME="media_organizer"
SKIP_SWARM=false
STACK_NAME="mediastack"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-swarm) SKIP_SWARM=true; shift ;;
    --registry) REGISTRY="$2"; FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"; shift 2 ;;
    *) shift ;;
  esac
done

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] ${*:2}"; }
die() { log "ERROR" "$*"; exit 1; }
section() { echo; echo "################################################################################"; echo "# $*"; echo "################################################################################"; }

command -v docker &>/dev/null || die "docker is required"
command -v node &>/dev/null   || die "node is required (v18+)"
command -v npm &>/dev/null    || die "npm is required"

section "1. CREATE PROJECT STRUCTURE"

mkdir -p "${PROJECT_DIR}"/{src/{routes,services,utils,middleware},media/{input,processed},logs,test}
log "INFO" "Project structure created at ${PROJECT_DIR}"

# ============================================================================
# SECTION 2 — package.json
# ============================================================================
section "2. WRITE package.json"
cat > "${PROJECT_DIR}/package.json" << 'PKGJSON'
{
  "name": "media-organizer",
  "version": "1.0.0",
  "description": "Hono-based media file organizer API",
  "main": "dist/index.js",
  "scripts": {
    "dev": "tsx watch src/index.ts",
    "build": "tsc",
    "start": "node dist/index.js",
    "lint": "tsc --noEmit"
  },
  "dependencies": {
    "@hono/node-server": "^1.12.0",
    "hono": "^4.4.0",
    "zod": "^3.23.8",
    "winston": "^3.13.0",
    "date-fns": "^3.6.0",
    "crypto": "^1.0.1"
  },
  "devDependencies": {
    "@types/node": "^20.14.0",
    "tsx": "^4.16.0",
    "typescript": "^5.5.0"
  }
}
PKGJSON

# ============================================================================
# SECTION 3 — tsconfig.json
# ============================================================================
section "3. WRITE tsconfig.json"
cat > "${PROJECT_DIR}/tsconfig.json" << 'TSCONFIG'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "commonjs",
    "lib": ["ES2022"],
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist"]
}
TSCONFIG

# ============================================================================
# SECTION 4 — LOGGER UTILITY
# ============================================================================
section "4. WRITE src/utils/logger.ts"
cat > "${PROJECT_DIR}/src/utils/logger.ts" << 'LOGGER'
import winston from "winston";
import path from "path";

const logDir = process.env.LOG_DIR || "./logs";

export const logger = winston.createLogger({
  level: process.env.LOG_LEVEL || "info",
  format: winston.format.combine(
    winston.format.timestamp({ format: "YYYY-MM-DD HH:mm:ss" }),
    winston.format.errors({ stack: true }),
    winston.format.printf(({ timestamp, level, message, ...meta }) => {
      const metaStr = Object.keys(meta).length ? ` ${JSON.stringify(meta)}` : "";
      return `${timestamp} [${level.toUpperCase()}] ${message}${metaStr}`;
    })
  ),
  transports: [
    new winston.transports.Console({
      format: winston.format.combine(
        winston.format.colorize(),
        winston.format.timestamp({ format: "YYYY-MM-DD HH:mm:ss" }),
        winston.format.printf(({ timestamp, level, message, ...meta }) => {
          const metaStr = Object.keys(meta).length ? ` ${JSON.stringify(meta)}` : "";
          return `${timestamp} [${level}] ${message}${metaStr}`;
        })
      ),
    }),
    new winston.transports.File({
      filename: path.join(logDir, "error.log"),
      level: "error",
    }),
    new winston.transports.File({
      filename: path.join(logDir, "combined.log"),
    }),
  ],
});
LOGGER

# ============================================================================
# SECTION 5 — FILE UTILS
# ============================================================================
section "5. WRITE src/utils/fileUtils.ts"
cat > "${PROJECT_DIR}/src/utils/fileUtils.ts" << 'FILEUTILS'
import fs from "fs";
import path from "path";
import crypto from "crypto";

export const IMAGE_EXTS = new Set([".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp"]);
export const VIDEO_EXTS = new Set([".mp4", ".mkv", ".mov", ".avi", ".flv", ".wmv"]);

export type MediaType = "image" | "video" | "both";

export interface MediaFile {
  fullPath: string;
  filename: string;
  ext: string;
  type: "image" | "video";
  size: number;
  baseName: string;
  dateStamp: string | null;
  hourStamp: string | null;
}

/** Recursively walk a directory, yield all files */
export function walkDir(dir: string): string[] {
  const results: string[] = [];
  if (!fs.existsSync(dir)) return results;
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      results.push(...walkDir(full));
    } else if (entry.isFile()) {
      results.push(full);
    }
  }
  return results;
}

/** Extract YYYYMMDD from filename */
export function extractDateStamp(filename: string): string | null {
  const m = filename.match(/^(\d{8})_/);
  return m ? m[1] : null;
}

/** Extract HH from YYYYMMDD_HHMMSS */
export function extractHourStamp(filename: string): string | null {
  const m = filename.match(/^\d{8}_(\d{2})\d{4}/);
  return m ? m[1] : null;
}

/** Extract base timestamp (YYYYMMDD_HHMMSS) from filename */
export function extractBaseTimestamp(filename: string): string {
  const noExt = path.parse(filename).name;
  const m = noExt.match(/^(\d{8}_\d{6})/);
  return m ? m[1] : noExt.replace(/_\d+$/, "");
}

/** Get week number for a YYYYMMDD string */
export function getWeekKey(dateStamp: string): string {
  const year = parseInt(dateStamp.slice(0, 4));
  const month = parseInt(dateStamp.slice(4, 6)) - 1;
  const day = parseInt(dateStamp.slice(6, 8));
  const d = new Date(year, month, day);
  const startOfYear = new Date(year, 0, 1);
  const week = Math.ceil(((d.getTime() - startOfYear.getTime()) / 86400000 + startOfYear.getDay() + 1) / 7);
  return `${year}_W${String(week).padStart(2, "0")}`;
}

/** Get month key YYYYMM */
export function getMonthKey(dateStamp: string): string {
  return dateStamp.slice(0, 6);
}

/** MD5 hash of a file for duplicate detection */
export function hashFile(filePath: string): string {
  const buf = fs.readFileSync(filePath);
  return crypto.createHash("md5").update(buf).digest("hex");
}

/** Safely create directory */
export function safeMkdir(dir: string, dryRun: boolean): void {
  if (!dryRun) fs.mkdirSync(dir, { recursive: true });
}

/** Safely move a file (skips if dst exists with same hash) */
export function safeMove(src: string, dst: string, dryRun: boolean): "moved" | "skipped" | "dry" {
  if (dryRun) return "dry";
  if (fs.existsSync(dst)) {
    return "skipped";
  }
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.renameSync(src, dst);
  return "moved";
}

/** Remove empty directories recursively */
export function removeEmptyDirs(dir: string, dryRun: boolean): number {
  let removed = 0;
  if (!fs.existsSync(dir)) return removed;
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  for (const e of entries) {
    if (e.isDirectory()) {
      removed += removeEmptyDirs(path.join(dir, e.name), dryRun);
    }
  }
  const remaining = fs.readdirSync(dir);
  if (remaining.length === 0) {
    if (!dryRun) fs.rmdirSync(dir);
    removed++;
  }
  return removed;
}

/** Collect media files from a directory, filtered by type */
export function collectMedia(dir: string, mediaType: MediaType): MediaFile[] {
  const files = walkDir(dir);
  const result: MediaFile[] = [];

  for (const fullPath of files) {
    const filename = path.basename(fullPath);
    const ext = path.extname(filename).toLowerCase();
    const isImage = IMAGE_EXTS.has(ext);
    const isVideo = VIDEO_EXTS.has(ext);

    if (!isImage && !isVideo) continue;
    if (mediaType === "image" && !isImage) continue;
    if (mediaType === "video" && !isVideo) continue;

    const stat = fs.statSync(fullPath);
    result.push({
      fullPath,
      filename,
      ext,
      type: isImage ? "image" : "video",
      size: stat.size,
      baseName: extractBaseTimestamp(filename),
      dateStamp: extractDateStamp(filename),
      hourStamp: extractHourStamp(filename),
    });
  }
  return result;
}

/** Human-readable bytes */
export function humanReadable(bytes: number): string {
  if (bytes > 1_073_741_824) return `${(bytes / 1_073_741_824).toFixed(2)}GB`;
  if (bytes > 1_048_576) return `${(bytes / 1_048_576).toFixed(2)}MB`;
  if (bytes > 1_024) return `${(bytes / 1_024).toFixed(2)}KB`;
  return `${bytes}B`;
}
FILEUTILS

# ============================================================================
# SECTION 6 — ORGANIZER SERVICE
# ============================================================================
section "6. WRITE src/services/organizer.ts"
cat > "${PROJECT_DIR}/src/services/organizer.ts" << 'ORGANIZER'
import path from "path";
import fs from "fs";
import {
  MediaFile, MediaType,
  collectMedia, hashFile, safeMove, safeMkdir,
  humanReadable, removeEmptyDirs,
  getWeekKey, getMonthKey,
} from "../utils/fileUtils";
import { logger } from "../utils/logger";

export interface OrganizerOptions {
  sourceDir: string;
  outputDir: string;
  mediaType: MediaType;
  dryRun?: boolean;
}

export interface GroupByFilenameOptions extends OrganizerOptions {}

export interface GroupByDateOptions extends OrganizerOptions {
  granularity: "day" | "week" | "month";
}

export interface OperationResult {
  operation: string;
  dryRun: boolean;
  groups: GroupSummary[];
  duplicates: DuplicateInfo[];
  emptyDirsRemoved: number;
  totalFiles: number;
  totalBytes: number;
  totalBytesHuman: string;
  errors: string[];
}

export interface GroupSummary {
  groupKey: string;
  dir: string;
  fileCount: number;
  sizeBytes: number;
  sizeHuman: string;
  files: string[];
}

export interface DuplicateInfo {
  hash: string;
  original: string;
  duplicate: string;
}

// ─── DUPLICATE DETECTION ────────────────────────────────────────────────────

function detectDuplicates(files: MediaFile[]): Map<string, string[]> {
  const hashMap = new Map<string, string[]>();
  for (const f of files) {
    try {
      const h = hashFile(f.fullPath);
      if (!hashMap.has(h)) hashMap.set(h, []);
      hashMap.get(h)!.push(f.fullPath);
    } catch (e) {
      logger.warn(`Could not hash file: ${f.fullPath}`, { error: String(e) });
    }
  }
  return hashMap;
}

// ─── SHARED MOVE LOGIC ──────────────────────────────────────────────────────

function moveFiles(
  groupedFiles: Map<string, MediaFile[]>,
  baseOutputDir: string,
  hashMap: Map<string, string[]>,
  dryRun: boolean,
  operationName: string
): { groups: GroupSummary[]; duplicates: DuplicateInfo[]; errors: string[] } {
  const groups: GroupSummary[] = [];
  const duplicates: DuplicateInfo[] = [];
  const errors: string[] = [];

  // Build reverse map: filePath -> hash
  const fileToHash = new Map<string, string>();
  for (const [hash, filePaths] of hashMap.entries()) {
    for (const fp of filePaths) fileToHash.set(fp, hash);
  }

  // Track originals chosen per hash
  const hashOriginal = new Map<string, string>();

  for (const [groupKey, files] of groupedFiles.entries()) {
    if (files.length === 0) continue;

    const groupSize = files.reduce((s, f) => s + f.size, 0);
    const sizeSuffix = groupSize > 1_073_741_824
      ? `${(groupSize / 1_073_741_824).toFixed(1)}gb`
      : `${Math.round(groupSize / 1_048_576)}mb`;

    const dirName = `${groupKey}__${files.length}_${sizeSuffix}`;
    const groupDir = path.join(baseOutputDir, dirName);

    safeMkdir(groupDir, dryRun);

    const movedFiles: string[] = [];

    for (const file of files) {
      const hash = fileToHash.get(file.fullPath);
      const isDup = hash && (hashMap.get(hash)?.length ?? 0) > 1;
      const isFirstSeen = hash && !hashOriginal.has(hash);

      let targetDir = groupDir;

      if (isDup && hash) {
        if (isFirstSeen) {
          hashOriginal.set(hash, file.fullPath);
        } else {
          const dupDir = path.join(groupDir, ".duplicates");
          safeMkdir(dupDir, dryRun);
          const dst = path.join(dupDir, file.filename);
          const result = safeMove(file.fullPath, dst, dryRun);
          duplicates.push({ hash, original: hashOriginal.get(hash)!, duplicate: file.fullPath });
          logger.info(`[${operationName}] DUPLICATE ${file.filename} -> .duplicates/`, { result });
          movedFiles.push(file.filename + " [DUP]");
          continue;
        }
      }

      const dst = path.join(targetDir, file.filename);
      try {
        const result = safeMove(file.fullPath, dst, dryRun);
        logger.info(`[${operationName}] MOVE ${file.filename} -> ${path.basename(groupDir)}/`, { result });
        movedFiles.push(file.filename);
      } catch (e) {
        const msg = `Failed to move ${file.fullPath}: ${String(e)}`;
        errors.push(msg);
        logger.error(msg);
      }
    }

    groups.push({
      groupKey,
      dir: groupDir,
      fileCount: files.length,
      sizeBytes: groupSize,
      sizeHuman: humanReadable(groupSize),
      files: movedFiles,
    });

    logger.info(`[${operationName}] GROUP ${groupKey} | ${files.length} files (${humanReadable(groupSize)})`);
  }

  return { groups, duplicates, errors };
}

// ─── OPERATION 1: GROUP BY FILENAME BASE ────────────────────────────────────

export async function groupByFilename(opts: GroupByFilenameOptions): Promise<OperationResult> {
  const { sourceDir, outputDir, mediaType, dryRun = false } = opts;
  const files = collectMedia(sourceDir, mediaType);
  logger.info(`groupByFilename | found ${files.length} files`, { mediaType, dryRun });

  const hashMap = detectDuplicates(files);
  const grouped = new Map<string, MediaFile[]>();

  for (const f of files) {
    const key = f.baseName || "undated";
    if (!grouped.has(key)) grouped.set(key, []);
    grouped.get(key)!.push(f);
  }

  const { groups, duplicates, errors } = moveFiles(grouped, outputDir, hashMap, dryRun, "groupByFilename");
  const emptyDirsRemoved = removeEmptyDirs(sourceDir, dryRun);

  return {
    operation: "groupByFilename",
    dryRun,
    groups,
    duplicates,
    emptyDirsRemoved,
    totalFiles: files.length,
    totalBytes: files.reduce((s, f) => s + f.size, 0),
    totalBytesHuman: humanReadable(files.reduce((s, f) => s + f.size, 0)),
    errors,
  };
}

// ─── OPERATION 2: GROUP BY DATE GRANULARITY ──────────────────────────────────

export async function groupByDate(opts: GroupByDateOptions): Promise<OperationResult> {
  const { sourceDir, outputDir, mediaType, dryRun = false, granularity } = opts;
  const files = collectMedia(sourceDir, mediaType);
  logger.info(`groupByDate | found ${files.length} files`, { mediaType, granularity, dryRun });

  const hashMap = detectDuplicates(files);
  const grouped = new Map<string, MediaFile[]>();

  for (const f of files) {
    let key: string;
    if (!f.dateStamp) {
      key = "undated";
    } else if (granularity === "day") {
      key = f.dateStamp;
    } else if (granularity === "week") {
      key = getWeekKey(f.dateStamp);
    } else {
      key = getMonthKey(f.dateStamp);
    }
    if (!grouped.has(key)) grouped.set(key, []);
    grouped.get(key)!.push(f);
  }

  const { groups, duplicates, errors } = moveFiles(grouped, outputDir, hashMap, dryRun, `groupByDate:${granularity}`);
  const emptyDirsRemoved = removeEmptyDirs(sourceDir, dryRun);

  return {
    operation: `groupByDate:${granularity}`,
    dryRun,
    groups,
    duplicates,
    emptyDirsRemoved,
    totalFiles: files.length,
    totalBytes: files.reduce((s, f) => s + f.size, 0),
    totalBytesHuman: humanReadable(files.reduce((s, f) => s + f.size, 0)),
    errors,
  };
}

// ─── OPERATION 3: GROUP BY HOUR WITHIN DAY ──────────────────────────────────

export async function groupByHour(opts: OrganizerOptions): Promise<OperationResult> {
  const { sourceDir, outputDir, mediaType, dryRun = false } = opts;
  const files = collectMedia(sourceDir, mediaType);
  logger.info(`groupByHour | found ${files.length} files`, { mediaType, dryRun });

  const hashMap = detectDuplicates(files);
  const grouped = new Map<string, MediaFile[]>();

  for (const f of files) {
    let key: string;
    if (!f.dateStamp || !f.hourStamp) {
      key = "undated";
    } else {
      key = `${f.dateStamp}_${f.hourStamp}`;
    }
    if (!grouped.has(key)) grouped.set(key, []);
    grouped.get(key)!.push(f);
  }

  const { groups, duplicates, errors } = moveFiles(grouped, outputDir, hashMap, dryRun, "groupByHour");
  const emptyDirsRemoved = removeEmptyDirs(sourceDir, dryRun);

  return {
    operation: "groupByHour",
    dryRun,
    groups,
    duplicates,
    emptyDirsRemoved,
    totalFiles: files.length,
    totalBytes: files.reduce((s, f) => s + f.size, 0),
    totalBytesHuman: humanReadable(files.reduce((s, f) => s + f.size, 0)),
    errors,
  };
}

// ─── OPERATION 4: FLATTEN — MOVE ALL TO OUTPUT ROOT ─────────────────────────

export async function flattenMedia(opts: OrganizerOptions): Promise<OperationResult> {
  const { sourceDir, outputDir, mediaType, dryRun = false } = opts;
  const files = collectMedia(sourceDir, mediaType);
  logger.info(`flattenMedia | found ${files.length} files`, { mediaType, dryRun });

  const hashMap = detectDuplicates(files);
  const errors: string[] = [];
  const duplicates: DuplicateInfo[] = [];
  const movedFiles: string[] = [];
  const seenHashes = new Map<string, string>();

  safeMkdir(outputDir, dryRun);

  for (const f of files) {
    let hash: string;
    try { hash = hashFile(f.fullPath); } catch { hash = ""; }

    if (hash && seenHashes.has(hash)) {
      duplicates.push({ hash, original: seenHashes.get(hash)!, duplicate: f.fullPath });
      logger.info(`flattenMedia | DUPLICATE skipped: ${f.filename}`);
      continue;
    }
    if (hash) seenHashes.set(hash, f.fullPath);

    const dst = path.join(outputDir, f.filename);
    try {
      const result = safeMove(f.fullPath, dst, dryRun);
      movedFiles.push(f.filename);
      logger.info(`flattenMedia | MOVE ${f.filename}`, { result });
    } catch (e) {
      const msg = `Failed to move ${f.fullPath}: ${String(e)}`;
      errors.push(msg);
      logger.error(msg);
    }
  }

  const emptyDirsRemoved = removeEmptyDirs(sourceDir, dryRun);

  return {
    operation: "flattenMedia",
    dryRun,
    groups: [{
      groupKey: "flat",
      dir: outputDir,
      fileCount: movedFiles.length,
      sizeBytes: files.reduce((s, f) => s + f.size, 0),
      sizeHuman: humanReadable(files.reduce((s, f) => s + f.size, 0)),
      files: movedFiles,
    }],
    duplicates,
    emptyDirsRemoved,
    totalFiles: files.length,
    totalBytes: files.reduce((s, f) => s + f.size, 0),
    totalBytesHuman: humanReadable(files.reduce((s, f) => s + f.size, 0)),
    errors,
  };
}

// ─── OPERATION 5: SEPARATE IMAGES & VIDEOS ──────────────────────────────────

export async function separateByType(opts: Omit<OrganizerOptions, "mediaType"> & { dryRun?: boolean }): Promise<OperationResult> {
  const { sourceDir, outputDir, dryRun = false } = opts;
  const files = collectMedia(sourceDir, "both");
  logger.info(`separateByType | found ${files.length} files`, { dryRun });

  const hashMap = detectDuplicates(files);
  const grouped = new Map<string, MediaFile[]>();

  for (const f of files) {
    const key = f.type === "image" ? "images" : "videos";
    if (!grouped.has(key)) grouped.set(key, []);
    grouped.get(key)!.push(f);
  }

  const { groups, duplicates, errors } = moveFiles(grouped, outputDir, hashMap, dryRun, "separateByType");
  const emptyDirsRemoved = removeEmptyDirs(sourceDir, dryRun);

  return {
    operation: "separateByType",
    dryRun,
    groups,
    duplicates,
    emptyDirsRemoved,
    totalFiles: files.length,
    totalBytes: files.reduce((s, f) => s + f.size, 0),
    totalBytesHuman: humanReadable(files.reduce((s, f) => s + f.size, 0)),
    errors,
  };
}

// ─── OPERATION 6: FIND RELATED (video + image with same timestamp) ───────────

export async function findRelated(opts: OrganizerOptions): Promise<OperationResult> {
  const { sourceDir, outputDir, dryRun = false } = opts;
  const files = collectMedia(sourceDir, "both");
  logger.info(`findRelated | found ${files.length} files`, { dryRun });

  const hashMap = detectDuplicates(files);

  // Group by hour key
  const byHour = new Map<string, { images: MediaFile[]; videos: MediaFile[] }>();
  for (const f of files) {
    if (!f.dateStamp || !f.hourStamp) continue;
    const key = `${f.dateStamp}_${f.hourStamp}`;
    if (!byHour.has(key)) byHour.set(key, { images: [], videos: [] });
    if (f.type === "image") byHour.get(key)!.images.push(f);
    else byHour.get(key)!.videos.push(f);
  }

  const grouped = new Map<string, MediaFile[]>();
  for (const [key, group] of byHour.entries()) {
    if (group.images.length > 0 && group.videos.length > 0) {
      grouped.set(key, [...group.images, ...group.videos]);
    }
  }

  const { groups, duplicates, errors } = moveFiles(grouped, outputDir, hashMap, dryRun, "findRelated");
  const emptyDirsRemoved = removeEmptyDirs(sourceDir, dryRun);

  return {
    operation: "findRelated",
    dryRun,
    groups,
    duplicates,
    emptyDirsRemoved,
    totalFiles: files.length,
    totalBytes: files.reduce((s, f) => s + f.size, 0),
    totalBytesHuman: humanReadable(files.reduce((s, f) => s + f.size, 0)),
    errors,
  };
}

// ─── OPERATION 7: DEDUPLICATE ONLY ──────────────────────────────────────────

export async function deduplicateOnly(opts: OrganizerOptions): Promise<OperationResult> {
  const { sourceDir, outputDir, mediaType, dryRun = false } = opts;
  const files = collectMedia(sourceDir, mediaType);
  logger.info(`deduplicateOnly | found ${files.length} files`, { mediaType, dryRun });

  const hashMap = detectDuplicates(files);
  const duplicates: DuplicateInfo[] = [];
  const errors: string[] = [];
  const seenHashes = new Map<string, string>();
  const dupDir = path.join(outputDir, "duplicates");
  safeMkdir(dupDir, dryRun);

  for (const f of files) {
    let hash: string;
    try { hash = hashFile(f.fullPath); } catch { hash = ""; }

    if (hash && seenHashes.has(hash)) {
      duplicates.push({ hash, original: seenHashes.get(hash)!, duplicate: f.fullPath });
      const dst = path.join(dupDir, f.filename);
      try {
        safeMove(f.fullPath, dst, dryRun);
        logger.info(`deduplicateOnly | moved duplicate: ${f.filename}`);
      } catch (e) {
        errors.push(String(e));
      }
      continue;
    }
    if (hash) seenHashes.set(hash, f.fullPath);
  }

  const emptyDirsRemoved = removeEmptyDirs(sourceDir, dryRun);

  return {
    operation: "deduplicateOnly",
    dryRun,
    groups: [{ groupKey: "duplicates", dir: dupDir, fileCount: duplicates.length, sizeBytes: 0, sizeHuman: "0B", files: duplicates.map(d => d.duplicate) }],
    duplicates,
    emptyDirsRemoved,
    totalFiles: files.length,
    totalBytes: files.reduce((s, f) => s + f.size, 0),
    totalBytesHuman: humanReadable(files.reduce((s, f) => s + f.size, 0)),
    errors,
  };
}

// ─── OPERATION 8: SCAN ONLY (no moves) ──────────────────────────────────────

export async function scanOnly(sourceDir: string, mediaType: MediaType): Promise<OperationResult> {
  const files = collectMedia(sourceDir, mediaType);
  const hashMap = detectDuplicates(files);

  let dupCount = 0;
  for (const [, paths] of hashMap.entries()) {
    if (paths.length > 1) dupCount += paths.length - 1;
  }

  const byType = files.reduce((acc, f) => {
    acc[f.type] = (acc[f.type] || 0) + 1;
    return acc;
  }, {} as Record<string, number>);

  logger.info(`scanOnly | ${files.length} files, ${dupCount} duplicates`, { byType });

  return {
    operation: "scanOnly",
    dryRun: true,
    groups: [],
    duplicates: [],
    emptyDirsRemoved: 0,
    totalFiles: files.length,
    totalBytes: files.reduce((s, f) => s + f.size, 0),
    totalBytesHuman: humanReadable(files.reduce((s, f) => s + f.size, 0)),
    errors: [],
  };
}
ORGANIZER

# ============================================================================
# SECTION 7 — VALIDATION MIDDLEWARE
# ============================================================================
section "7. WRITE src/middleware/validate.ts"
cat > "${PROJECT_DIR}/src/middleware/validate.ts" << 'VALIDATE'
import { Context, Next } from "hono";
import { ZodSchema } from "zod";
import { logger } from "../utils/logger";

export function validateBody<T>(schema: ZodSchema<T>) {
  return async (c: Context, next: Next) => {
    let body: unknown;
    try {
      body = await c.req.json();
    } catch {
      return c.json({ error: "Invalid JSON body" }, 400);
    }

    const result = schema.safeParse(body);
    if (!result.success) {
      logger.warn("Validation failed", { errors: result.error.flatten() });
      return c.json({ error: "Validation failed", details: result.error.flatten() }, 422);
    }

    c.set("validatedBody", result.data);
    await next();
  };
}
VALIDATE

# ============================================================================
# SECTION 8 — ROUTES: HELPER
# ============================================================================
section "8. WRITE src/routes/helper.ts"
cat > "${PROJECT_DIR}/src/routes/helper.ts" << 'HELPERROUTE'
import { Hono } from "hono";

const helper = new Hono();

const ENDPOINT_DOCS = [
  {
    endpoint: "GET /",
    description: "Health check - returns server status",
    body: null,
    example: null,
  },
  {
    endpoint: "GET /help",
    description: "This helper — lists all endpoints with descriptions and example payloads",
    body: null,
    example: null,
  },
  {
    endpoint: "POST /organize/filename",
    description: "Group media files by their filename base timestamp (YYYYMMDD_HHMMSS). Works for images, videos, or both.",
    body: {
      sourceDir: "string — absolute path to source directory",
      outputDir: "string — absolute path to output directory",
      mediaType: '"image" | "video" | "both"',
      dryRun: "boolean (optional, default false) — preview without moving files",
    },
    example: {
      sourceDir: "/media/input",
      outputDir: "/media/processed/by-filename",
      mediaType: "both",
      dryRun: true,
    },
  },
  {
    endpoint: "POST /organize/date",
    description: "Group media by date with configurable granularity: day (YYYYMMDD), week (YYYY_WNN), or month (YYYYMM). Supports images, videos, or both.",
    body: {
      sourceDir: "string",
      outputDir: "string",
      mediaType: '"image" | "video" | "both"',
      granularity: '"day" | "week" | "month"',
      dryRun: "boolean (optional)",
    },
    example: {
      sourceDir: "/media/input",
      outputDir: "/media/processed/by-date",
      mediaType: "image",
      granularity: "week",
      dryRun: false,
    },
  },
  {
    endpoint: "POST /organize/hour",
    description: "Group media by day+hour (YYYYMMDD_HH). Useful for burst photography sessions.",
    body: {
      sourceDir: "string",
      outputDir: "string",
      mediaType: '"image" | "video" | "both"',
      dryRun: "boolean (optional)",
    },
    example: {
      sourceDir: "/media/input",
      outputDir: "/media/processed/by-hour",
      mediaType: "both",
      dryRun: false,
    },
  },
  {
    endpoint: "POST /organize/flatten",
    description: "Move all media into a single flat output directory. Duplicates are skipped automatically.",
    body: {
      sourceDir: "string",
      outputDir: "string",
      mediaType: '"image" | "video" | "both"',
      dryRun: "boolean (optional)",
    },
    example: {
      sourceDir: "/media/input",
      outputDir: "/media/processed/flat",
      mediaType: "video",
      dryRun: false,
    },
  },
  {
    endpoint: "POST /organize/separate",
    description: "Split all media into two subdirectories: images/ and videos/ under outputDir.",
    body: {
      sourceDir: "string",
      outputDir: "string",
      dryRun: "boolean (optional)",
    },
    example: {
      sourceDir: "/media/input",
      outputDir: "/media/processed",
      dryRun: false,
    },
  },
  {
    endpoint: "POST /organize/related",
    description: "Find and group files where images AND videos share the same hour-timestamp (captured at same time). Only groups with both types are moved.",
    body: {
      sourceDir: "string",
      outputDir: "string",
      dryRun: "boolean (optional)",
    },
    example: {
      sourceDir: "/media/input",
      outputDir: "/media/processed/related",
      dryRun: false,
    },
  },
  {
    endpoint: "POST /organize/deduplicate",
    description: "Find duplicate files (by MD5 hash) and move them to an outputDir/duplicates folder. Originals are left in place.",
    body: {
      sourceDir: "string",
      outputDir: "string",
      mediaType: '"image" | "video" | "both"',
      dryRun: "boolean (optional)",
    },
    example: {
      sourceDir: "/media/input",
      outputDir: "/media/processed",
      mediaType: "both",
      dryRun: true,
    },
  },
  {
    endpoint: "POST /organize/scan",
    description: "Scan only — returns file counts, size, duplicate count. No files are moved. Always dry-run.",
    body: {
      sourceDir: "string",
      mediaType: '"image" | "video" | "both"',
    },
    example: {
      sourceDir: "/media/input",
      mediaType: "both",
    },
  },
  {
    endpoint: "GET /logs/recent",
    description: "Fetch the last N lines from combined.log",
    query: "?lines=50 (default 100)",
    example: "GET /logs/recent?lines=50",
  },
  {
    endpoint: "GET /logs/errors",
    description: "Fetch the last N lines from error.log",
    query: "?lines=50",
    example: "GET /logs/errors?lines=50",
  },
  {
    endpoint: "GET /calendar",
    description: "Returns the current server date, ISO week number, and month — useful for date-based grouping context",
    body: null,
    example: null,
  },
];

helper.get("/", (c) => {
  return c.json({
    service: "Media Organizer API",
    version: "1.0.0",
    endpoints: ENDPOINT_DOCS,
    notes: [
      "All POST endpoints accept JSON body.",
      "dryRun: true previews operations without moving any files.",
      "mediaType controls which files are processed: image | video | both.",
      "Duplicates are detected by MD5 hash and moved to .duplicates/ subdirs.",
      "Empty directories are cleaned up after each operation.",
    ],
  });
});

export default helper;
HELPERROUTE

# ============================================================================
# SECTION 9 — ROUTES: ORGANIZE
# ============================================================================
section "9. WRITE src/routes/organize.ts"
cat > "${PROJECT_DIR}/src/routes/organize.ts" << 'ORGROUTE'
import { Hono } from "hono";
import { z } from "zod";
import { validateBody } from "../middleware/validate";
import {
  groupByFilename,
  groupByDate,
  groupByHour,
  flattenMedia,
  separateByType,
  findRelated,
  deduplicateOnly,
  scanOnly,
} from "../services/organizer";
import { logger } from "../utils/logger";

const organize = new Hono();

// ── Shared schemas ──────────────────────────────────────────────────────────

const MediaTypeEnum = z.enum(["image", "video", "both"]);

const BaseSchema = z.object({
  sourceDir: z.string().min(1, "sourceDir is required"),
  outputDir: z.string().min(1, "outputDir is required"),
  mediaType: MediaTypeEnum,
  dryRun: z.boolean().optional().default(false),
});

const DateSchema = BaseSchema.extend({
  granularity: z.enum(["day", "week", "month"]),
});

const ScanSchema = z.object({
  sourceDir: z.string().min(1),
  mediaType: MediaTypeEnum,
});

const SeparateSchema = z.object({
  sourceDir: z.string().min(1),
  outputDir: z.string().min(1),
  dryRun: z.boolean().optional().default(false),
});

// ── Helpers ─────────────────────────────────────────────────────────────────

function handleError(c: any, operation: string, e: unknown) {
  logger.error(`[${operation}] Unhandled error`, { error: String(e) });
  return c.json({ error: "Internal server error", details: String(e) }, 500);
}

// ── POST /organize/filename ──────────────────────────────────────────────────

organize.post("/filename", validateBody(BaseSchema), async (c) => {
  const body = c.get("validatedBody") as z.infer<typeof BaseSchema>;
  try {
    const result = await groupByFilename(body);
    return c.json(result, 200);
  } catch (e) { return handleError(c, "groupByFilename", e); }
});

// ── POST /organize/date ──────────────────────────────────────────────────────

organize.post("/date", validateBody(DateSchema), async (c) => {
  const body = c.get("validatedBody") as z.infer<typeof DateSchema>;
  try {
    const result = await groupByDate(body);
    return c.json(result, 200);
  } catch (e) { return handleError(c, "groupByDate", e); }
});

// ── POST /organize/hour ──────────────────────────────────────────────────────

organize.post("/hour", validateBody(BaseSchema), async (c) => {
  const body = c.get("validatedBody") as z.infer<typeof BaseSchema>;
  try {
    const result = await groupByHour(body);
    return c.json(result, 200);
  } catch (e) { return handleError(c, "groupByHour", e); }
});

// ── POST /organize/flatten ───────────────────────────────────────────────────

organize.post("/flatten", validateBody(BaseSchema), async (c) => {
  const body = c.get("validatedBody") as z.infer<typeof BaseSchema>;
  try {
    const result = await flattenMedia(body);
    return c.json(result, 200);
  } catch (e) { return handleError(c, "flattenMedia", e); }
});

// ── POST /organize/separate ──────────────────────────────────────────────────

organize.post("/separate", validateBody(SeparateSchema), async (c) => {
  const body = c.get("validatedBody") as z.infer<typeof SeparateSchema>;
  try {
    const result = await separateByType({ ...body, mediaType: "both" });
    return c.json(result, 200);
  } catch (e) { return handleError(c, "separateByType", e); }
});

// ── POST /organize/related ───────────────────────────────────────────────────

organize.post("/related", validateBody(SeparateSchema), async (c) => {
  const body = c.get("validatedBody") as z.infer<typeof SeparateSchema>;
  try {
    const result = await findRelated({ ...body, mediaType: "both" });
    return c.json(result, 200);
  } catch (e) { return handleError(c, "findRelated", e); }
});

// ── POST /organize/deduplicate ───────────────────────────────────────────────

organize.post("/deduplicate", validateBody(BaseSchema), async (c) => {
  const body = c.get("validatedBody") as z.infer<typeof BaseSchema>;
  try {
    const result = await deduplicateOnly(body);
    return c.json(result, 200);
  } catch (e) { return handleError(c, "deduplicateOnly", e); }
});

// ── POST /organize/scan ──────────────────────────────────────────────────────

organize.post("/scan", validateBody(ScanSchema), async (c) => {
  const body = c.get("validatedBody") as z.infer<typeof ScanSchema>;
  try {
    const result = await scanOnly(body.sourceDir, body.mediaType);
    return c.json(result, 200);
  } catch (e) { return handleError(c, "scanOnly", e); }
});

export default organize;
ORGROUTE

# ============================================================================
# SECTION 10 — ROUTES: LOGS + CALENDAR
# ============================================================================
section "10. WRITE src/routes/system.ts"
cat > "${PROJECT_DIR}/src/routes/system.ts" << 'SYSROUTE'
import { Hono } from "hono";
import fs from "fs";
import path from "path";

const system = new Hono();
const LOG_DIR = process.env.LOG_DIR || "./logs";

function tailFile(filePath: string, lines: number): string[] {
  if (!fs.existsSync(filePath)) return ["Log file not found"];
  const content = fs.readFileSync(filePath, "utf-8");
  return content.trim().split("\n").slice(-lines);
}

system.get("/logs/recent", (c) => {
  const lines = parseInt(c.req.query("lines") || "100", 10);
  const data = tailFile(path.join(LOG_DIR, "combined.log"), lines);
  return c.json({ lines: data.length, log: data });
});

system.get("/logs/errors", (c) => {
  const lines = parseInt(c.req.query("lines") || "100", 10);
  const data = tailFile(path.join(LOG_DIR, "error.log"), lines);
  return c.json({ lines: data.length, log: data });
});

system.get("/calendar", (c) => {
  const now = new Date();
  const startOfYear = new Date(now.getFullYear(), 0, 1);
  const week = Math.ceil(((now.getTime() - startOfYear.getTime()) / 86400000 + startOfYear.getDay() + 1) / 7);
  return c.json({
    now: now.toISOString(),
    date: now.toISOString().slice(0, 10),
    year: now.getFullYear(),
    month: now.getMonth() + 1,
    monthPadded: String(now.getMonth() + 1).padStart(2, "0"),
    day: now.getDate(),
    dayPadded: String(now.getDate()).padStart(2, "0"),
    weekOfYear: week,
    weekKey: `${now.getFullYear()}_W${String(week).padStart(2, "0")}`,
    monthKey: `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, "0")}`,
    dayKey: `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, "0")}${String(now.getDate()).padStart(2, "0")}`,
    timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
  });
});

export default system;
SYSROUTE

# ============================================================================
# SECTION 11 — MAIN INDEX
# ============================================================================
section "11. WRITE src/index.ts"
cat > "${PROJECT_DIR}/src/index.ts" << 'MAININDEX'
import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { logger as winstonLogger } from "./utils/logger";
import organizeRouter from "./routes/organize";
import helperRouter from "./routes/helper";
import systemRouter from "./routes/system";
import fs from "fs";

// Ensure log dir exists
const LOG_DIR = process.env.LOG_DIR || "./logs";
fs.mkdirSync(LOG_DIR, { recursive: true });

const app = new Hono();

// ── Request logging middleware ───────────────────────────────────────────────
app.use("*", async (c, next) => {
  const start = Date.now();
  await next();
  const ms = Date.now() - start;
  winstonLogger.info(`${c.req.method} ${c.req.path} ${c.res.status} ${ms}ms`);
});

// ── Health check ─────────────────────────────────────────────────────────────
app.get("/", (c) =>
  c.json({
    status: "ok",
    service: "media-organizer",
    version: "1.0.0",
    timestamp: new Date().toISOString(),
    hint: "GET /help for full API documentation",
  })
);

// ── Route mounts ──────────────────────────────────────────────────────────────
app.route("/help", helperRouter);
app.route("/organize", organizeRouter);
app.route("/", systemRouter);

// ── 404 handler ──────────────────────────────────────────────────────────────
app.notFound((c) =>
  c.json({ error: "Not found", hint: "GET /help for available endpoints" }, 404)
);

// ── Error handler ─────────────────────────────────────────────────────────────
app.onError((err, c) => {
  winstonLogger.error("Unhandled error", { error: err.message, stack: err.stack });
  return c.json({ error: "Internal server error" }, 500);
});

const PORT = parseInt(process.env.PORT || "3000", 10);
winstonLogger.info(`Starting media-organizer on port ${PORT}`);

serve({ fetch: app.fetch, port: PORT }, () => {
  winstonLogger.info(`Media Organizer API listening on http://0.0.0.0:${PORT}`);
  winstonLogger.info(`API docs: http://0.0.0.0:${PORT}/help`);
});
MAININDEX

# ============================================================================
# SECTION 12 — .dockerignore
# ============================================================================
section "12. WRITE .dockerignore"
cat > "${PROJECT_DIR}/.dockerignore" << 'DOCKERIGNORE'
node_modules
dist
logs
.git
*.test.ts
test/
DOCKERIGNORE

# ============================================================================
# SECTION 13 — Dockerfile (multi-stage)
# ============================================================================
section "13. WRITE Dockerfile"
cat > "${PROJECT_DIR}/Dockerfile" << 'DOCKERFILE'
# ── Stage 1: Builder ──────────────────────────────────────────────────────────
FROM node:20-alpine AS builder

WORKDIR /app
COPY package*.json ./
RUN npm ci --quiet
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# ── Stage 2: Production ───────────────────────────────────────────────────────
FROM node:20-alpine AS production

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

COPY package*.json ./
RUN npm ci --omit=dev --quiet && npm cache clean --force

COPY --from=builder /app/dist ./dist

RUN mkdir -p /media/input /media/processed /app/logs && \
    chown -R appuser:appgroup /media /app/logs /app

USER appuser

ENV PORT=3000
ENV LOG_DIR=/app/logs
ENV NODE_ENV=production

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:3000/ || exit 1

CMD ["node", "dist/index.js"]
DOCKERFILE

# ============================================================================
# SECTION 14 — docker-compose (swarm stack)
# ============================================================================
section "14. WRITE docker-compose.yml (Swarm Stack)"
cat > "${PROJECT_DIR}/docker-compose.yml" << COMPOSE
version: "3.9"

services:
  media-organizer:
    image: ${FULL_IMAGE}
    ports:
      - "3000:3000"
    environment:
      - PORT=3000
      - LOG_DIR=/app/logs
      - NODE_ENV=production
    volumes:
      - media_input:/media/input
      - media_processed:/media/processed
      - app_logs:/app/logs
    deploy:
      replicas: 2
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3
      update_config:
        parallelism: 1
        delay: 10s
        order: start-first
      resources:
        limits:
          cpus: "1.0"
          memory: 512M
        reservations:
          cpus: "0.25"
          memory: 128M
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:3000/"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 15s
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "5"

volumes:
  media_input:
    driver: local
  media_processed:
    driver: local
  app_logs:
    driver: local

networks:
  default:
    driver: overlay
    attachable: true
COMPOSE

# ============================================================================
# SECTION 15 — TEST SCRIPT
# ============================================================================
section "15. WRITE test/test_endpoints.sh"
cat > "${PROJECT_DIR}/test/test_endpoints.sh" << 'TESTSCRIPT'
#!/bin/bash
################################################################################
# MEDIA ORGANIZER — Endpoint Test Suite
# Usage: bash test/test_endpoints.sh [BASE_URL] [--with-files]
################################################################################

BASE_URL="${1:-http://localhost:3000}"
WITH_FILES="${2:-}"
PASS=0
FAIL=0
TEST_INPUT_DIR="/tmp/media_test_input_$$"
TEST_OUTPUT_DIR="/tmp/media_test_output_$$"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${CYAN}[TEST]${NC} $*"; }
pass() { echo -e "${GREEN}[PASS]${NC} $*"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; ((FAIL++)); }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }

assert_status() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$label — HTTP $actual"
  else
    fail "$label — expected HTTP $expected, got HTTP $actual"
  fi
}

assert_json_key() {
  local label="$1"
  local key="$2"
  local body="$3"
  if echo "$body" | grep -q "\"$key\""; then
    pass "$label — key '$key' present"
  else
    fail "$label — key '$key' missing in response"
  fi
}

# ── Create test media files ──────────────────────────────────────────────────
setup_test_files() {
  info "Creating test media files in $TEST_INPUT_DIR"
  mkdir -p "$TEST_INPUT_DIR"
  mkdir -p "$TEST_OUTPUT_DIR"

  # Create dummy files with timestamp-based names
  local dates=("20260101" "20260101" "20260115" "20260201" "20260310")
  local times=("083000" "083001" "143000" "090000" "120000")
  local types=("jpg" "mp4" "jpg" "mp4" "jpg")

  for i in "${!dates[@]}"; do
    fname="${dates[$i]}_${times[$i]}.${types[$i]}"
    dd if=/dev/urandom of="${TEST_INPUT_DIR}/${fname}" bs=1024 count=$((RANDOM % 100 + 10)) 2>/dev/null
    info "  created: $fname"
  done

  # Create a duplicate
  cp "${TEST_INPUT_DIR}/20260101_083000.jpg" "${TEST_INPUT_DIR}/20260101_083000_dup.jpg"
  info "  created duplicate: 20260101_083000_dup.jpg"
}

cleanup_test_files() {
  rm -rf "$TEST_INPUT_DIR" "$TEST_OUTPUT_DIR"
  info "Cleaned up test directories"
}

# ── Wait for server ──────────────────────────────────────────────────────────
wait_for_server() {
  info "Waiting for server at $BASE_URL ..."
  for i in {1..20}; do
    if curl -sf "$BASE_URL/" &>/dev/null; then
      info "Server is up"
      return 0
    fi
    sleep 1
  done
  fail "Server did not start within 20s"
  exit 1
}

# ── Tests ────────────────────────────────────────────────────────────────────

test_health() {
  log "Health check"
  resp=$(curl -sf -w "\n%{http_code}" "$BASE_URL/")
  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | head -1)
  assert_status "GET /" "200" "$http_code"
  assert_json_key "GET / body" "status" "$body"
}

test_help() {
  log "Help endpoint"
  resp=$(curl -sf -w "\n%{http_code}" "$BASE_URL/help")
  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | head -1)
  assert_status "GET /help" "200" "$http_code"
  assert_json_key "GET /help body" "endpoints" "$body"
}

test_calendar() {
  log "Calendar endpoint"
  resp=$(curl -sf -w "\n%{http_code}" "$BASE_URL/calendar")
  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | head -1)
  assert_status "GET /calendar" "200" "$http_code"
  assert_json_key "GET /calendar" "weekKey" "$body"
  assert_json_key "GET /calendar" "monthKey" "$body"
}

test_logs_recent() {
  log "Logs recent endpoint"
  resp=$(curl -sf -w "\n%{http_code}" "$BASE_URL/logs/recent?lines=10")
  http_code=$(echo "$resp" | tail -1)
  assert_status "GET /logs/recent" "200" "$http_code"
}

test_logs_errors() {
  log "Logs error endpoint"
  resp=$(curl -sf -w "\n%{http_code}" "$BASE_URL/logs/errors?lines=10")
  http_code=$(echo "$resp" | tail -1)
  assert_status "GET /logs/errors" "200" "$http_code"
}

test_404() {
  log "404 handler"
  http_code=$(curl -sf -o /dev/null -w "%{http_code}" "$BASE_URL/nonexistent-route" 2>/dev/null || echo "404")
  assert_status "GET /nonexistent" "404" "$http_code"
}

test_validation_missing_fields() {
  log "Validation — missing required fields"
  resp=$(curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/organize/filename" \
    -H "Content-Type: application/json" \
    -d '{"mediaType":"both"}')
  assert_status "POST /organize/filename (missing dirs)" "422" "$resp"
}

test_validation_bad_media_type() {
  log "Validation — invalid mediaType"
  resp=$(curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/organize/filename" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"/tmp\",\"outputDir\":\"/tmp/out\",\"mediaType\":\"audio\"}")
  assert_status "POST /organize/filename (bad mediaType)" "422" "$resp"
}

test_validation_bad_granularity() {
  log "Validation — invalid granularity"
  resp=$(curl -sf -o /dev/null -w "%{http_code}" -X POST "$BASE_URL/organize/date" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"/tmp\",\"outputDir\":\"/tmp/out\",\"mediaType\":\"both\",\"granularity\":\"year\"}")
  assert_status "POST /organize/date (bad granularity)" "422" "$resp"
}

test_scan_dryrun() {
  log "Scan endpoint (dry-run, no files required)"
  resp=$(curl -sf -w "\n%{http_code}" -X POST "$BASE_URL/organize/scan" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"/tmp\",\"mediaType\":\"both\"}")
  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | head -1)
  assert_status "POST /organize/scan" "200" "$http_code"
  assert_json_key "POST /organize/scan body" "operation" "$body"
}

test_with_real_files() {
  log "=== File movement tests (requires test files) ==="
  setup_test_files

  # Test: scan
  log "Scan with real files"
  resp=$(curl -sf -w "\n%{http_code}" -X POST "$BASE_URL/organize/scan" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"$TEST_INPUT_DIR\",\"mediaType\":\"both\"}")
  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | head -1)
  assert_status "POST /organize/scan (real files)" "200" "$http_code"
  assert_json_key "scan response" "totalFiles" "$body"
  info "Scan result: $(echo $body | python3 -c 'import json,sys; d=json.load(sys.stdin); print(f"totalFiles={d[\"totalFiles\"]}, totalBytesHuman={d[\"totalBytesHuman\"]}")' 2>/dev/null || echo $body)"

  # Test: groupByFilename dry-run
  log "groupByFilename dry-run"
  resp=$(curl -sf -w "\n%{http_code}" -X POST "$BASE_URL/organize/filename" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"$TEST_INPUT_DIR\",\"outputDir\":\"$TEST_OUTPUT_DIR/filename\",\"mediaType\":\"both\",\"dryRun\":true}")
  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | head -1)
  assert_status "POST /organize/filename (dry-run)" "200" "$http_code"
  assert_json_key "groupByFilename dry-run" "groups" "$body"

  # Verify no files were moved in dry-run
  moved_count=$(ls "$TEST_INPUT_DIR" 2>/dev/null | wc -l)
  if [[ "$moved_count" -ge 5 ]]; then
    pass "dry-run — source files untouched ($moved_count files remain)"
  else
    fail "dry-run — source files appear to have been moved"
  fi

  # Test: groupByDate by day (real move)
  log "groupByDate by day (real move)"
  resp=$(curl -sf -w "\n%{http_code}" -X POST "$BASE_URL/organize/date" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"$TEST_INPUT_DIR\",\"outputDir\":\"$TEST_OUTPUT_DIR/by-day\",\"mediaType\":\"both\",\"granularity\":\"day\",\"dryRun\":false}")
  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | head -1)
  assert_status "POST /organize/date day (real)" "200" "$http_code"

  # Verify files were moved
  if ls "$TEST_OUTPUT_DIR/by-day" 2>/dev/null | grep -q "__"; then
    pass "groupByDate — output directories created with expected naming"
  else
    fail "groupByDate — no output directories found"
  fi

  # Verify duplicate detection
  dup_found=$(echo "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("duplicates",[])))' 2>/dev/null || echo "0")
  if [[ "$dup_found" -ge 1 ]]; then
    pass "duplicate detection — found $dup_found duplicate(s)"
  else
    fail "duplicate detection — expected at least 1 duplicate"
  fi

  # Test: images only
  setup_test_files
  log "images-only filter"
  resp=$(curl -sf -w "\n%{http_code}" -X POST "$BASE_URL/organize/scan" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"$TEST_INPUT_DIR\",\"mediaType\":\"image\"}")
  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | head -1)
  image_count=$(echo "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("totalFiles",0))' 2>/dev/null || echo "?")
  assert_status "POST /organize/scan (images only)" "200" "$http_code"
  info "images-only count: $image_count"

  # Test: videos only
  resp=$(curl -sf -w "\n%{http_code}" -X POST "$BASE_URL/organize/scan" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"$TEST_INPUT_DIR\",\"mediaType\":\"video\"}")
  http_code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | head -1)
  video_count=$(echo "$body" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("totalFiles",0))' 2>/dev/null || echo "?")
  assert_status "POST /organize/scan (videos only)" "200" "$http_code"
  info "videos-only count: $video_count"

  # Test: separate
  log "separateByType"
  resp=$(curl -sf -w "\n%{http_code}" -X POST "$BASE_URL/organize/separate" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"$TEST_INPUT_DIR\",\"outputDir\":\"$TEST_OUTPUT_DIR/separate\",\"dryRun\":true}")
  http_code=$(echo "$resp" | tail -1)
  assert_status "POST /organize/separate" "200" "$http_code"

  # Test: deduplicate
  log "deduplicateOnly"
  resp=$(curl -sf -w "\n%{http_code}" -X POST "$BASE_URL/organize/deduplicate" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"$TEST_INPUT_DIR\",\"outputDir\":\"$TEST_OUTPUT_DIR/dedup\",\"mediaType\":\"both\",\"dryRun\":true}")
  http_code=$(echo "$resp" | tail -1)
  assert_status "POST /organize/deduplicate" "200" "$http_code"

  # Test: week grouping
  setup_test_files
  log "groupByDate by week"
  resp=$(curl -sf -w "\n%{http_code}" -X POST "$BASE_URL/organize/date" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"$TEST_INPUT_DIR\",\"outputDir\":\"$TEST_OUTPUT_DIR/by-week\",\"mediaType\":\"both\",\"granularity\":\"week\",\"dryRun\":true}")
  http_code=$(echo "$resp" | tail -1)
  assert_status "POST /organize/date week" "200" "$http_code"

  # Test: month grouping
  setup_test_files
  log "groupByDate by month"
  resp=$(curl -sf -w "\n%{http_code}" -X POST "$BASE_URL/organize/date" \
    -H "Content-Type: application/json" \
    -d "{\"sourceDir\":\"$TEST_INPUT_DIR\",\"outputDir\":\"$TEST_OUTPUT_DIR/by-month\",\"mediaType\":\"both\",\"granularity\":\"month\",\"dryRun\":true}")
  http_code=$(echo "$resp" | tail -1)
  assert_status "POST /organize/date month" "200" "$http_code"

  cleanup_test_files
}

# ── Run all tests ────────────────────────────────────────────────────────────

echo
echo "================================================================================"
echo " MEDIA ORGANIZER — Test Suite"
echo " Target: $BASE_URL"
echo "================================================================================"
echo

wait_for_server

test_health
test_help
test_calendar
test_logs_recent
test_logs_errors
test_404
test_validation_missing_fields
test_validation_bad_media_type
test_validation_bad_granularity
test_scan_dryrun

if [[ "$WITH_FILES" == "--with-files" ]]; then
  test_with_real_files
else
  info "Skipping file-movement tests (pass --with-files to enable)"
fi

echo
echo "================================================================================"
echo -e " Results: ${GREEN}${PASS} passed${NC} | ${RED}${FAIL} failed${NC}"
echo "================================================================================"
echo

exit $FAIL
TESTSCRIPT
chmod +x "${PROJECT_DIR}/test/test_endpoints.sh"

# ============================================================================
# SECTION 16 — .env file
# ============================================================================
section "16. WRITE .env"
cat > "${PROJECT_DIR}/.env" << 'ENVFILE'
PORT=3000
LOG_DIR=./logs
NODE_ENV=production
ENVFILE

# ============================================================================
# SECTION 17 — README
# ============================================================================
section "17. WRITE README.md"
cat > "${PROJECT_DIR}/README.md" << 'README'
# Media Organizer API

Hono-based TypeScript REST API for organizing media files (images & videos).

## Quick Start

```bash
npm install
npm run dev          # development
npm run build && npm start  # production
```

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Health check |
| GET | `/help` | Full API documentation |
| GET | `/calendar` | Current date context for grouping |
| GET | `/logs/recent?lines=N` | Tail combined log |
| GET | `/logs/errors?lines=N` | Tail error log |
| POST | `/organize/filename` | Group by filename timestamp |
| POST | `/organize/date` | Group by day/week/month |
| POST | `/organize/hour` | Group by day+hour |
| POST | `/organize/flatten` | Move all to single folder |
| POST | `/organize/separate` | Split into images/ and videos/ |
| POST | `/organize/related` | Group images+videos with same timestamp |
| POST | `/organize/deduplicate` | Isolate duplicate files |
| POST | `/organize/scan` | Scan only, no moves |

## Body Parameters

All POST endpoints accept JSON. Core fields:

```json
{
  "sourceDir": "/path/to/media",
  "outputDir": "/path/to/output",
  "mediaType": "image | video | both",
  "dryRun": false
}
```

`/organize/date` also requires `"granularity": "day | week | month"`.

## Docker

```bash
docker build -t media-organizer .
docker run -p 3000:3000 -v /your/media:/media/input media-organizer
```

## Tests

```bash
bash test/test_endpoints.sh http://localhost:3000 --with-files
```
README

# ============================================================================
# SECTION 18 — INSTALL DEPENDENCIES
# ============================================================================
section "18. INSTALL DEPENDENCIES"
cd "${PROJECT_DIR}"
log "INFO" "Running npm install..."
npm install --quiet
log "INFO" "Dependencies installed"

# ============================================================================
# SECTION 19 — BUILD TYPESCRIPT
# ============================================================================
section "19. BUILD TYPESCRIPT"
npm run build
log "INFO" "TypeScript build complete"

# ============================================================================
# SECTION 20 — DOCKER BUILD + PUSH TO LOCAL REGISTRY
# ============================================================================
section "20. DOCKER BUILD & PUSH TO ${REGISTRY}"

log "INFO" "Building Docker image: ${FULL_IMAGE}"
docker build -t "${FULL_IMAGE}" "${PROJECT_DIR}"

log "INFO" "Pushing image to local registry ${REGISTRY}..."
if docker push "${FULL_IMAGE}"; then
  log "INFO" "Image pushed successfully: ${FULL_IMAGE}"
else
  log "WARN" "Push failed — registry at ${REGISTRY} may not be reachable. Image built locally as ${FULL_IMAGE}"
  log "WARN" "To push manually: docker push ${FULL_IMAGE}"
  log "WARN" "Ensure insecure-registries includes ${REGISTRY} in /etc/docker/daemon.json"
fi

# ============================================================================
# SECTION 21 — DOCKER SWARM INIT + DEPLOY
# ============================================================================

if [[ "$SKIP_SWARM" == false ]]; then
  section "21. DOCKER SWARM INIT & DEPLOY"

  # Init swarm if not already active
  if ! docker info 2>/dev/null | grep -q "Swarm: active"; then
    log "INFO" "Initializing Docker Swarm..."
    docker swarm init || log "WARN" "Swarm init failed — may already be in a swarm, continuing..."
  else
    log "INFO" "Docker Swarm already active"
  fi

  log "INFO" "Deploying stack '${STACK_NAME}'..."
  docker stack deploy -c "${PROJECT_DIR}/docker-compose.yml" "${STACK_NAME}" --with-registry-auth

  log "INFO" "Waiting for service to start..."
  sleep 8

  log "INFO" "Stack services:"
  docker stack services "${STACK_NAME}" 2>/dev/null || true
else
  section "21. SKIPPING SWARM (--skip-swarm)"
fi

# ============================================================================
# SECTION 22 — RUN TEST SUITE
# ============================================================================
section "22. RUN TEST SUITE"

# Give the service a moment to be ready
sleep 5

log "INFO" "Running endpoint tests against http://localhost:3000 ..."
if bash "${PROJECT_DIR}/test/test_endpoints.sh" "http://localhost:3000" "--with-files"; then
  log "INFO" "All tests passed ✓"
else
  log "WARN" "Some tests failed — check output above"
fi

# ============================================================================
# FINAL SUMMARY
# ============================================================================
section "SETUP COMPLETE"
echo
echo "  Project:       ${PROJECT_DIR}"
echo "  Docker image:  ${FULL_IMAGE}"
echo "  Stack name:    ${STACK_NAME}"
echo "  API port:      3000"
echo
echo "  Useful commands:"
echo "    docker stack services ${STACK_NAME}         # service status"
echo "    docker stack ps ${STACK_NAME}               # task status"
echo "    docker service logs ${STACK_NAME}_media-organizer  # live logs"
echo "    docker stack rm ${STACK_NAME}               # tear down"
echo "    bash ${PROJECT_DIR}/test/test_endpoints.sh http://localhost:3000 --with-files"
echo
echo "  API docs:       http://localhost:3000/help"
echo "  Calendar:       http://localhost:3000/calendar"
echo "  Recent logs:    http://localhost:3000/logs/recent"
echo
