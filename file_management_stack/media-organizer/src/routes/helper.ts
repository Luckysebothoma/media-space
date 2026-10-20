// src/routes/helper.ts  — drop-in replacement
import { Hono } from "hono";

const helper = new Hono();

const ENDPOINT_DOCS = [
  {
    method: "GET",
    endpoint: "/",
    description: "Health check — returns server status, version, and a hint to /help.",
    body: null,
    example: null,
    response_shape: { status: "ok", service: "media-organizer", version: "1.0.0", timestamp: "<ISO>" },
  },
  {
    method: "GET",
    endpoint: "/help",
    description: "This document — full API reference with examples for every endpoint.",
    body: null,
    example: null,
    response_shape: { service: "string", endpoints: "EndpointDoc[]", notes: "string[]" },
  },
  {
    method: "GET",
    endpoint: "/calendar",
    description: "Returns the current server date broken into every key format used by the organizer (dayKey, weekKey, monthKey). Query this before building date-based payloads.",
    body: null,
    example: null,
    response_shape: {
      now: "<ISO timestamp>",
      date: "YYYY-MM-DD",
      year: 2026,
      month: 3,
      weekOfYear: 12,
      weekKey: "2026_W12",
      monthKey: "202603",
      dayKey: "20260322",
      timezone: "Africa/Johannesburg",
    },
  },
  {
    method: "GET",
    endpoint: "/logs/recent",
    description: "Tail the combined log (all levels). Query param: ?lines=N (default 100).",
    body: null,
    example: "GET /logs/recent?lines=50",
    response_shape: { lines: 50, log: ["<log line>", "..."] },
  },
  {
    method: "GET",
    endpoint: "/logs/errors",
    description: "Tail the error log only. Query param: ?lines=N (default 100).",
    body: null,
    example: "GET /logs/errors?lines=20",
    response_shape: { lines: 20, log: ["<error line>", "..."] },
  },

  // ── Scan ──────────────────────────────────────────────────────────────────
  {
    method: "POST",
    endpoint: "/organize/scan",
    description: "Read-only inventory. Counts files, total size, and detects duplicates. NEVER moves any file — safe as a preflight check before any operation.",
    body: {
      sourceDir: "string — absolute path to scan (searched recursively)",
      mediaType: "'image' | 'video' | 'both'",
    },
    example: {
      body: {
        sourceDir: "/media/input",
        mediaType: "both",
      },
    },
    response_shape: {
      operation: "scanOnly",
      dryRun: true,
      totalFiles: 42,
      totalBytesHuman: "1.23GB",
      groups: [],
      duplicates: [],
      errors: [],
    },
  },

  // ── Group by filename ─────────────────────────────────────────────────────
  {
    method: "POST",
    endpoint: "/organize/filename",
    description: "Groups files that share the same base timestamp in their filename (YYYYMMDD_HHMMSS). e.g. 20260322_075059.mp4 and 20260322_075059_1.jpg are placed together. Output folders are named: {timestamp}__{count}_{size}.",
    body: {
      sourceDir: "string — source directory (recursive)",
      outputDir: "string — where grouped folders are created",
      mediaType: "'image' | 'video' | 'both'",
      dryRun: "boolean (optional, default false) — true = preview, no files moved",
    },
    example: {
      body: {
        sourceDir: "/media/input",
        outputDir: "/media/processed/by-filename",
        mediaType: "both",
        dryRun: true,
      },
    },
    response_shape: {
      operation: "groupByFilename",
      dryRun: true,
      totalFiles: 10,
      totalBytesHuman: "450MB",
      groups: [
        {
          groupKey: "20260322_075059",
          dir: "/media/processed/by-filename/20260322_075059__2_12mb",
          fileCount: 2,
          sizeHuman: "12MB",
          files: ["20260322_075059.mp4", "20260322_075059_1.jpg"],
        },
      ],
      duplicates: [],
      emptyDirsRemoved: 0,
      errors: [],
    },
  },

  // ── Group by date ─────────────────────────────────────────────────────────
  {
    method: "POST",
    endpoint: "/organize/date",
    description: "Groups media by date at three granularities. day → YYYYMMDD folders. week → YYYY_WNN folders (ISO week). month → YYYYMM folders. Use GET /calendar to see the current keys before sending.",
    body: {
      sourceDir: "string",
      outputDir: "string",
      mediaType: "'image' | 'video' | 'both'",
      granularity: "'day' | 'week' | 'month'",
      dryRun: "boolean (optional)",
    },
    example: {
      "by day": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed/by-day",
          mediaType: "both",
          granularity: "day",
          dryRun: true,
        },
      },
      "by week": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed/by-week",
          mediaType: "image",
          granularity: "week",
          dryRun: false,
        },
      },
      "by month": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed/by-month",
          mediaType: "video",
          granularity: "month",
          dryRun: false,
        },
      },
    },
    response_shape: {
      operation: "groupByDate:day",
      dryRun: true,
      totalFiles: 30,
      totalBytesHuman: "2.1GB",
      groups: [
        {
          groupKey: "20260322",
          dir: "/media/processed/by-day/20260322__8_800mb",
          fileCount: 8,
          sizeHuman: "800MB",
          files: ["20260322_075059.jpg", "..."],
        },
      ],
      duplicates: [],
      emptyDirsRemoved: 2,
      errors: [],
    },
  },

  // ── Group by hour ─────────────────────────────────────────────────────────
  {
    method: "POST",
    endpoint: "/organize/hour",
    description: "Groups media captured within the same hour of the same day. Output folders: YYYYMMDD_HH__{count}_{size}. Ideal for burst photography or hourly time-lapses.",
    body: {
      sourceDir: "string",
      outputDir: "string",
      mediaType: "'image' | 'video' | 'both'",
      dryRun: "boolean (optional)",
    },
    example: {
      body: {
        sourceDir: "/media/input",
        outputDir: "/media/processed/by-hour",
        mediaType: "both",
        dryRun: true,
      },
    },
    response_shape: {
      operation: "groupByHour",
      groups: [
        {
          groupKey: "20260322_07",
          dir: "/media/processed/by-hour/20260322_07__5_200mb",
          fileCount: 5,
          sizeHuman: "200MB",
          files: ["20260322_073000.jpg", "..."],
        },
      ],
    },
  },

  // ── Flatten ───────────────────────────────────────────────────────────────
  {
    method: "POST",
    endpoint: "/organize/flatten",
    description: "Moves all matching media into a single flat outputDir. Duplicate files (by MD5) are automatically skipped — only unique files land. Useful to consolidate scattered media before a re-sort.",
    body: {
      sourceDir: "string",
      outputDir: "string",
      mediaType: "'image' | 'video' | 'both'",
      dryRun: "boolean (optional)",
    },
    example: {
      body: {
        sourceDir: "/media/input",
        outputDir: "/media/processed/flat",
        mediaType: "both",
        dryRun: false,
      },
    },
    response_shape: {
      operation: "flattenMedia",
      groups: [{ groupKey: "flat", fileCount: 28, sizeHuman: "1.8GB" }],
      duplicates: [],
    },
  },

  // ── Separate ──────────────────────────────────────────────────────────────
  {
    method: "POST",
    endpoint: "/organize/separate",
    description: "Splits all media under sourceDir into two typed subdirectories: outputDir/images__N_Xmb and outputDir/videos__N_Xmb. mediaType is always 'both' — no filter field needed.",
    body: {
      sourceDir: "string",
      outputDir: "string — parent; images/ and videos/ are created inside",
      dryRun: "boolean (optional)",
    },
    example: {
      body: {
        sourceDir: "/media/input",
        outputDir: "/media/processed",
        dryRun: false,
      },
    },
    response_shape: {
      operation: "separateByType",
      groups: [
        { groupKey: "images", fileCount: 20, sizeHuman: "400MB" },
        { groupKey: "videos", fileCount: 5, sizeHuman: "1.4GB" },
      ],
    },
  },

  // ── Related ───────────────────────────────────────────────────────────────
  {
    method: "POST",
    endpoint: "/organize/related",
    description: "Finds hours where BOTH images AND videos share the same timestamp. Only groups containing at least one image and one video are moved. Perfect for cameras that capture a still + clip simultaneously.",
    body: {
      sourceDir: "string",
      outputDir: "string",
      dryRun: "boolean (optional)",
    },
    example: {
      body: {
        sourceDir: "/media/input",
        outputDir: "/media/processed/related",
        dryRun: true,
      },
    },
    response_shape: {
      operation: "findRelated",
      groups: [
        {
          groupKey: "20260322_07",
          fileCount: 3,
          files: ["20260322_075059.jpg", "20260322_075059.mp4", "20260322_075101.jpg"],
        },
      ],
    },
  },

  // ── Deduplicate ───────────────────────────────────────────────────────────
  {
    method: "POST",
    endpoint: "/organize/deduplicate",
    description: "MD5-hashes every file. Keeps the first occurrence in place. All subsequent identical files are moved to outputDir/duplicates/. Always run with dryRun: true first to see the count before committing.",
    body: {
      sourceDir: "string",
      outputDir: "string — duplicates/ subfolder is created here",
      mediaType: "'image' | 'video' | 'both'",
      dryRun: "boolean (optional, STRONGLY recommend true first)",
    },
    example: {
      "dry-run first": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed",
          mediaType: "both",
          dryRun: true,
        },
      },
      "real move": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed",
          mediaType: "both",
          dryRun: false,
        },
      },
    },
    response_shape: {
      operation: "deduplicateOnly",
      duplicates: [
        {
          hash: "d41d8cd98f00b204e9800998ecf8427e",
          original: "/media/input/20260101_083000.jpg",
          duplicate: "/media/input/20260101_083000_dup.jpg",
        },
      ],
    },
  },
];

// ── Validation error shape for reference ────────────────────────────────────

const VALIDATION_ERRORS_REFERENCE = {
  description: "All POST endpoints validate with Zod. Invalid payloads return HTTP 422.",
  shape: {
    error: "Validation failed",
    details: {
      formErrors: [],
      fieldErrors: {
        sourceDir: ["Required"],
        mediaType: ["Invalid enum value. Expected 'image' | 'video' | 'both', received 'audio'"],
        granularity: ["Invalid enum value. Expected 'day' | 'week' | 'month', received 'year'"],
      },
    },
  },
};

const NOTES = [
  "All POST /organize/* endpoints accept a JSON body.",
  "dryRun: true previews the operation — no files are moved. Always try this first.",
  "mediaType: 'image' | 'video' | 'both' — controls which files are processed.",
  "Duplicates are detected by MD5 hash and routed to a .duplicates/ subfolder.",
  "Empty source directories are cleaned up after each operation automatically.",
  "Use GET /calendar to retrieve weekKey / monthKey / dayKey for date operations.",
  "Use GET /logs/recent and GET /logs/errors to audit what happened after a run.",
];

helper.get("/", (c) => {
  return c.json({
    service: "Media Organizer API",
    version: "1.0.0",
    generated: new Date().toISOString(),
    endpoints: ENDPOINT_DOCS,
    validation_error_reference: VALIDATION_ERRORS_REFERENCE,
    notes: NOTES,
  });
});

export default helper;