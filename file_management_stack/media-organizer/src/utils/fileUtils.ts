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
export function safeMove(
  src: string,
  dst: string,
  dryRun: boolean
): "moved" | "skipped" | "dry" {

  if (dryRun) return "dry";

  if (fs.existsSync(dst)) {
    return "skipped";
  }

  fs.mkdirSync(path.dirname(dst), { recursive: true });

  try {
    // 🔥 Fast path (same device)
    fs.renameSync(src, dst);
  } catch (err: any) {
    if (err.code === "EXDEV") {
      // 🚀 Cross-device fallback
      fs.copyFileSync(src, dst);
      fs.unlinkSync(src);
    } else {
      throw err;
    }
  }

  return "moved";
}

/** Remove empty directories recursively */
export function removeEmptyDirs(dir: string, dryRun: boolean, rootDir?: string): number {
  let removed = 0;

  if (!fs.existsSync(dir)) return removed;

  const entries = fs.readdirSync(dir, { withFileTypes: true });

  for (const e of entries) {
    if (e.isDirectory()) {
      removed += removeEmptyDirs(path.join(dir, e.name), dryRun, rootDir);
    }
  }

  const remaining = fs.readdirSync(dir);

  // 🚨 NEVER delete rootDir
  if (remaining.length === 0 && dir !== rootDir) {
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
