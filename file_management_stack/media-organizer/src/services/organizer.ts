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
export async function separateByType(
  opts: Omit<OrganizerOptions, "mediaType"> & { dryRun?: boolean }
): Promise<OperationResult> {
  const { sourceDir, outputDir, dryRun = false } = opts;

  const files = collectMedia(sourceDir, "both");

  logger.info(`separateByType | found ${files.length} files`, {
    dryRun,
    sourceDir,
    outputDir,
  });

  if (files.length === 0) {
    return {
      operation: "separateByType",
      dryRun,
      groups: [],
      duplicates: [],
      emptyDirsRemoved: 0,
      totalFiles: 0,
      totalBytes: 0,
      totalBytesHuman: "0B",
      errors: [],
    };
  }

  const hashMap = detectDuplicates(files);
  const grouped = new Map<string, MediaFile[]>();

  for (const f of files) {
    const key = f.type === "image" ? "images" : "videos";
    if (!grouped.has(key)) grouped.set(key, []);
    grouped.get(key)!.push(f);
  }

  const { groups, duplicates, errors } = await moveFiles(
    grouped,
    outputDir,
    hashMap,
    dryRun,
    "separateByType"
  );

  const emptyDirsRemoved = removeEmptyDirs(sourceDir, dryRun);

  const totalBytes = files.reduce((s, f) => s + f.size, 0);

  return {
    operation: "separateByType",
    dryRun,
    groups,
    duplicates,
    emptyDirsRemoved,
    totalFiles: files.length,
    totalBytes,
    totalBytesHuman: humanReadable(totalBytes),
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
