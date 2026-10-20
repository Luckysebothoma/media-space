// ============================================================================
// api-guide.ts
// Full API consumer guide — mount on index.ts via: app.route("/guide", apiGuide)
// Access at: GET /guide
// ============================================================================

import { Hono } from "hono";

const apiGuide = new Hono();

// ── Types ────────────────────────────────────────────────────────────────────

interface BodyField {
  [key: string]: string;
}

interface Example {
  [label: string]: {
    body?: Record<string, unknown>;
    curl?: string;
    note?: string;
  };
}

interface EndpointDoc {
  method: "GET" | "POST";
  path: string;
  description: string;
  movesFiles: boolean;
  bodyFields: BodyField | null;
  examples: Example;
  responseSample?: Record<string, unknown>;
  errorCodes?: Record<number, string>;
}

// ── Section 1 — System & Utility ─────────────────────────────────────────────

const systemEndpoints: EndpointDoc[] = [
  {
    method: "GET",
    path: "/",
    description:
      "Health check. Returns server status, version, and a hint to /guide. " +
      "No body required. Use this to verify the service is alive before any operation.",
    movesFiles: false,
    bodyFields: null,
    examples: {
      "health check": {
        curl: `curl -s http://HOST:3000/`,
        note: "Expect HTTP 200 with status: ok",
      },
    },
    responseSample: {
      status: "ok",
      service: "media-organizer",
      version: "1.0.0",
      timestamp: "2026-04-14T08:00:00.000Z",
      hint: "GET /guide for full API documentation",
    },
    errorCodes: {},
  },

  {
    method: "GET",
    path: "/help",
    description:
      "Returns every endpoint with description, required body fields, and ready-to-copy JSON examples. " +
      "This is your built-in reference card served directly from the API.",
    movesFiles: false,
    bodyFields: null,
    examples: {
      "fetch docs": {
        curl: `curl -s http://HOST:3000/help`,
      },
    },
    responseSample: {
      service: "Media Organizer API",
      version: "1.0.0",
      endpoints: ["EndpointDoc[]"],
      notes: ["string[]"],
    },
    errorCodes: {},
  },

  {
    method: "GET",
    path: "/guide",
    description:
      "This document. Full consumer guide with all endpoints, examples, workflows, " +
      "validation behaviour, and a quick-reference card.",
    movesFiles: false,
    bodyFields: null,
    examples: {
      "fetch guide": {
        curl: `curl -s http://HOST:3000/guide`,
      },
    },
    responseSample: { message: "See full guide JSON at this endpoint" },
    errorCodes: {},
  },

  {
    method: "GET",
    path: "/calendar",
    description:
      "Returns the current server date broken into every key format used by the organizer: " +
      "dayKey (YYYYMMDD), monthKey (YYYYMM), weekKey (YYYY_WNN). " +
      "Query this before building date-based payloads so your keys match.",
    movesFiles: false,
    bodyFields: null,
    examples: {
      "get date context": {
        curl: `curl -s http://HOST:3000/calendar`,
        note: "Use weekKey / monthKey / dayKey values in /organize/date payloads",
      },
    },
    responseSample: {
      now: "2026-04-14T08:00:00.000Z",
      date: "2026-04-14",
      year: 2026,
      month: 4,
      monthPadded: "04",
      day: 14,
      dayPadded: "14",
      weekOfYear: 16,
      weekKey: "2026_W16",
      monthKey: "202604",
      dayKey: "20260414",
      timezone: "Africa/Johannesburg",
    },
    errorCodes: {},
  },

  {
    method: "GET",
    path: "/logs/recent",
    description:
      "Tail the combined log (all levels: info, warn, error). " +
      "Query param: ?lines=N (default 100). " +
      "Use this after any operation to confirm what was moved.",
    movesFiles: false,
    bodyFields: null,
    examples: {
      "last 20 lines": {
        curl: `curl -s "http://HOST:3000/logs/recent?lines=20"`,
      },
      "last 5 lines (quick sanity check)": {
        curl: `curl -s "http://HOST:3000/logs/recent?lines=5"`,
      },
    },
    responseSample: {
      lines: 5,
      log: [
        "2026-04-14 08:00:01 [INFO] GET / 200 0ms",
        "2026-04-14 08:00:05 [INFO] POST /organize/scan 200 12ms",
      ],
    },
    errorCodes: {},
  },

  {
    method: "GET",
    path: "/logs/errors",
    description:
      "Tail the error log only. " +
      "Query param: ?lines=N (default 100). " +
      "Check here when an operation returns errors in its response.",
    movesFiles: false,
    bodyFields: null,
    examples: {
      "last 10 errors": {
        curl: `curl -s "http://HOST:3000/logs/errors?lines=10"`,
      },
    },
    responseSample: {
      lines: 1,
      log: ["2026-04-14 08:00:10 [ERROR] Failed to move /media/input/file.jpg: EACCES"],
    },
    errorCodes: {},
  },
];

// ── Section 2 — Scan (read-only) ─────────────────────────────────────────────

const scanEndpoints: EndpointDoc[] = [
  {
    method: "POST",
    path: "/organize/scan",
    description:
      "Read-only inventory. Counts files, calculates total size, and detects duplicate files by MD5 hash. " +
      "NEVER moves any file — safe to run at any time as a preflight check before any destructive operation. " +
      "Always run this first on a new directory.",
    movesFiles: false,
    bodyFields: {
      sourceDir: "string — absolute path to the directory to scan (searched recursively)",
      mediaType: "'image' | 'video' | 'both'",
    },
    examples: {
      "scan everything": {
        body: {
          sourceDir: "/media/input",
          mediaType: "both",
        },
        curl: `curl -s -X POST http://HOST:3000/organize/scan \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","mediaType":"both"}'`,
      },
      "scan images only": {
        body: {
          sourceDir: "/media/input",
          mediaType: "image",
        },
        curl: `curl -s -X POST http://HOST:3000/organize/scan \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","mediaType":"image"}'`,
      },
      "scan videos only": {
        body: {
          sourceDir: "/media/input",
          mediaType: "video",
        },
        curl: `curl -s -X POST http://HOST:3000/organize/scan \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","mediaType":"video"}'`,
      },
    },
    responseSample: {
      operation: "scanOnly",
      dryRun: true,
      totalFiles: 42,
      totalBytesHuman: "1.23GB",
      groups: [],
      duplicates: [],
      emptyDirsRemoved: 0,
      errors: [],
    },
    errorCodes: { 422: "Missing sourceDir or invalid mediaType" },
  },
];

// ── Section 3 — Group by Filename ─────────────────────────────────────────────

const filenameEndpoints: EndpointDoc[] = [
  {
    method: "POST",
    path: "/organize/filename",
    description:
      "Groups files that share the same base timestamp in their filename (YYYYMMDD_HHMMSS). " +
      "Example: 20260322_075059.mp4 and 20260322_075059_1.jpg are placed together. " +
      "Output folder naming pattern: {timestamp}__{count}_{size}mb. " +
      "Duplicate files are detected by MD5 and moved to a .duplicates/ subfolder.",
    movesFiles: true,
    bodyFields: {
      sourceDir: "string — source directory (searched recursively)",
      outputDir: "string — where grouped folders are created",
      mediaType: "'image' | 'video' | 'both'",
      dryRun: "boolean (optional, default false) — true = preview only, no files moved",
    },
    examples: {
      "dry-run — both types": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed/by-filename",
          mediaType: "both",
          dryRun: true,
        },
        curl: `curl -s -X POST http://HOST:3000/organize/filename \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed/by-filename","mediaType":"both","dryRun":true}'`,
        note: "Run dry-run first to preview groupings before committing",
      },
      "real move — images only": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed/by-filename",
          mediaType: "image",
          dryRun: false,
        },
        curl: `curl -s -X POST http://HOST:3000/organize/filename \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed/by-filename","mediaType":"image","dryRun":false}'`,
      },
      "real move — videos only": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed/by-filename",
          mediaType: "video",
          dryRun: false,
        },
        curl: `curl -s -X POST http://HOST:3000/organize/filename \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed/by-filename","mediaType":"video","dryRun":false}'`,
      },
    },
    responseSample: {
      operation: "groupByFilename",
      dryRun: false,
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
      emptyDirsRemoved: 1,
      errors: [],
    },
    errorCodes: {
      422: "Missing sourceDir, outputDir, or invalid mediaType",
    },
  },
];

// ── Section 4 — Group by Date ─────────────────────────────────────────────────

const dateEndpoints: EndpointDoc[] = [
  {
    method: "POST",
    path: "/organize/date",
    description:
      "Groups media by date at three configurable granularities. " +
      "day → YYYYMMDD folders. " +
      "week → YYYY_WNN folders (ISO week number). " +
      "month → YYYYMM folders. " +
      "Use GET /calendar first to see the current dayKey, weekKey, and monthKey values. " +
      "Files without a recognisable date in their filename go to an 'undated' folder.",
    movesFiles: true,
    bodyFields: {
      sourceDir: "string",
      outputDir: "string",
      mediaType: "'image' | 'video' | 'both'",
      granularity: "'day' | 'week' | 'month'",
      dryRun: "boolean (optional, default false)",
    },
    examples: {
      "by day — dry-run": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed/by-day",
          mediaType: "both",
          granularity: "day",
          dryRun: true,
        },
        curl: `curl -s -X POST http://HOST:3000/organize/date \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed/by-day","mediaType":"both","granularity":"day","dryRun":true}'`,
      },
      "by day — images only, real move": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed/by-day",
          mediaType: "image",
          granularity: "day",
          dryRun: false,
        },
        curl: `curl -s -X POST http://HOST:3000/organize/date \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed/by-day","mediaType":"image","granularity":"day","dryRun":false}'`,
      },
      "by week — dry-run": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed/by-week",
          mediaType: "both",
          granularity: "week",
          dryRun: true,
        },
        curl: `curl -s -X POST http://HOST:3000/organize/date \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed/by-week","mediaType":"both","granularity":"week","dryRun":true}'`,
        note: "Output folders will look like: 2026_W16__8_800mb",
      },
      "by week — videos only": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed/by-week",
          mediaType: "video",
          granularity: "week",
          dryRun: false,
        },
        curl: `curl -s -X POST http://HOST:3000/organize/date \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed/by-week","mediaType":"video","granularity":"week","dryRun":false}'`,
      },
      "by month — dry-run": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed/by-month",
          mediaType: "both",
          granularity: "month",
          dryRun: true,
        },
        curl: `curl -s -X POST http://HOST:3000/organize/date \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed/by-month","mediaType":"both","granularity":"month","dryRun":true}'`,
        note: "Output folders will look like: 202604__30_2gb",
      },
      "by month — images only": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed/by-month",
          mediaType: "image",
          granularity: "month",
          dryRun: false,
        },
        curl: `curl -s -X POST http://HOST:3000/organize/date \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed/by-month","mediaType":"image","granularity":"month","dryRun":false}'`,
      },
    },
    responseSample: {
      operation: "groupByDate:day",
      dryRun: false,
      totalFiles: 30,
      totalBytesHuman: "2.1GB",
      groups: [
        {
          groupKey: "20260322",
          dir: "/media/processed/by-day/20260322__8_800mb",
          fileCount: 8,
          sizeHuman: "800MB",
          files: ["20260322_075059.jpg", "20260322_091200.jpg"],
        },
      ],
      duplicates: [],
      emptyDirsRemoved: 2,
      errors: [],
    },
    errorCodes: {
      422: "Missing fields or invalid granularity. granularity must be 'day' | 'week' | 'month'",
    },
  },
];

// ── Section 5 — Group by Hour ─────────────────────────────────────────────────

const hourEndpoints: EndpointDoc[] = [
  {
    method: "POST",
    path: "/organize/hour",
    description:
      "Groups media captured within the same hour of the same day. " +
      "Output folder pattern: YYYYMMDD_HH__{count}_{size}. " +
      "Ideal for burst photography sessions or time-lapses where per-hour isolation is needed.",
    movesFiles: true,
    bodyFields: {
      sourceDir: "string",
      outputDir: "string",
      mediaType: "'image' | 'video' | 'both'",
      dryRun: "boolean (optional, default false)",
    },
    examples: {
      "dry-run preview": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed/by-hour",
          mediaType: "both",
          dryRun: true,
        },
        curl: `curl -s -X POST http://HOST:3000/organize/hour \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed/by-hour","mediaType":"both","dryRun":true}'`,
      },
      "real move — images only": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed/by-hour",
          mediaType: "image",
          dryRun: false,
        },
        curl: `curl -s -X POST http://HOST:3000/organize/hour \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed/by-hour","mediaType":"image","dryRun":false}'`,
      },
    },
    responseSample: {
      operation: "groupByHour",
      groups: [
        {
          groupKey: "20260322_07",
          dir: "/media/processed/by-hour/20260322_07__5_200mb",
          fileCount: 5,
          sizeHuman: "200MB",
          files: ["20260322_073000.jpg", "20260322_075059.jpg"],
        },
      ],
    },
    errorCodes: { 422: "Missing sourceDir, outputDir, or invalid mediaType" },
  },
];

// ── Section 6 — Flatten ───────────────────────────────────────────────────────

const flattenEndpoints: EndpointDoc[] = [
  {
    method: "POST",
    path: "/organize/flatten",
    description:
      "Moves every matching file into one flat outputDir. " +
      "Duplicate files (detected by MD5) are automatically skipped — only unique files land. " +
      "Useful to consolidate scattered media from nested subdirectories before a re-sort.",
    movesFiles: true,
    bodyFields: {
      sourceDir: "string",
      outputDir: "string",
      mediaType: "'image' | 'video' | 'both'",
      dryRun: "boolean (optional, default false)",
    },
    examples: {
      "flatten all — dry-run": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed/flat",
          mediaType: "both",
          dryRun: true,
        },
        curl: `curl -s -X POST http://HOST:3000/organize/flatten \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed/flat","mediaType":"both","dryRun":true}'`,
      },
      "flatten videos only": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed/flat-videos",
          mediaType: "video",
          dryRun: false,
        },
        curl: `curl -s -X POST http://HOST:3000/organize/flatten \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed/flat-videos","mediaType":"video","dryRun":false}'`,
      },
      "flatten images only": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed/flat-images",
          mediaType: "image",
          dryRun: false,
        },
        curl: `curl -s -X POST http://HOST:3000/organize/flatten \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed/flat-images","mediaType":"image","dryRun":false}'`,
      },
    },
    responseSample: {
      operation: "flattenMedia",
      groups: [{ groupKey: "flat", fileCount: 28, sizeHuman: "1.8GB" }],
      duplicates: [],
    },
    errorCodes: { 422: "Missing required fields" },
  },
];

// ── Section 7 — Separate ──────────────────────────────────────────────────────

const separateEndpoints: EndpointDoc[] = [
  {
    method: "POST",
    path: "/organize/separate",
    description:
      "Splits all media under sourceDir into two typed subdirectories: " +
      "outputDir/images__{N}_{size} and outputDir/videos__{N}_{size}. " +
      "mediaType is always 'both' for this endpoint — no filter field is needed. " +
      "Duplicate files are moved to .duplicates/ as with all other operations.",
    movesFiles: true,
    bodyFields: {
      sourceDir: "string",
      outputDir: "string — images/ and videos/ are created inside this parent",
      dryRun: "boolean (optional, default false)",
    },
    examples: {
      "separate — dry-run": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed",
          dryRun: true,
        },
        curl: `curl -s -X POST http://HOST:3000/organize/separate \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed","dryRun":true}'`,
      },
      "separate — real move": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed",
          dryRun: false,
        },
        curl: `curl -s -X POST http://HOST:3000/organize/separate \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed","dryRun":false}'`,
      },
    },
    responseSample: {
      operation: "separateByType",
      groups: [
        { groupKey: "images", fileCount: 20, sizeHuman: "400MB" },
        { groupKey: "videos", fileCount: 5, sizeHuman: "1.4GB" },
      ],
    },
    errorCodes: { 422: "Missing sourceDir or outputDir" },
  },
];

// ── Section 8 — Related ───────────────────────────────────────────────────────

const relatedEndpoints: EndpointDoc[] = [
  {
    method: "POST",
    path: "/organize/related",
    description:
      "Finds hours where BOTH images AND videos share the same timestamp. " +
      "Only groups containing at least one image and one video are moved. " +
      "Groups with a single type are left untouched. " +
      "Perfect for cameras that capture a still + video clip simultaneously.",
    movesFiles: true,
    bodyFields: {
      sourceDir: "string",
      outputDir: "string",
      dryRun: "boolean (optional, default false)",
    },
    examples: {
      "find related — dry-run": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed/related",
          dryRun: true,
        },
        curl: `curl -s -X POST http://HOST:3000/organize/related \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed/related","dryRun":true}'`,
        note: "Only groups with both images AND videos will appear in the response",
      },
      "find related — real move": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed/related",
          dryRun: false,
        },
        curl: `curl -s -X POST http://HOST:3000/organize/related \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed/related","dryRun":false}'`,
      },
    },
    responseSample: {
      operation: "findRelated",
      groups: [
        {
          groupKey: "20260322_07",
          fileCount: 3,
          files: ["20260322_075059.jpg", "20260322_075059.mp4", "20260322_075101.jpg"],
        },
      ],
    },
    errorCodes: { 422: "Missing sourceDir or outputDir" },
  },
];

// ── Section 9 — Deduplicate ───────────────────────────────────────────────────

const deduplicateEndpoints: EndpointDoc[] = [
  {
    method: "POST",
    path: "/organize/deduplicate",
    description:
      "MD5-hashes every file. Keeps the first occurrence in place. " +
      "All subsequent identical files are moved to outputDir/duplicates/. " +
      "Strongly recommended: always run with dryRun: true first to see the duplicate count " +
      "before committing. This is non-destructive — duplicates are moved, not deleted.",
    movesFiles: true,
    bodyFields: {
      sourceDir: "string",
      outputDir: "string — a duplicates/ subfolder is created inside this path",
      mediaType: "'image' | 'video' | 'both'",
      dryRun: "boolean (optional — STRONGLY recommend true on first run)",
    },
    examples: {
      "dry-run first (recommended)": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed",
          mediaType: "both",
          dryRun: true,
        },
        curl: `curl -s -X POST http://HOST:3000/organize/deduplicate \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed","mediaType":"both","dryRun":true}'`,
        note: "Check the duplicates[] array in the response before committing",
      },
      "real move — all types": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed",
          mediaType: "both",
          dryRun: false,
        },
        curl: `curl -s -X POST http://HOST:3000/organize/deduplicate \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed","mediaType":"both","dryRun":false}'`,
      },
      "images only": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed",
          mediaType: "image",
          dryRun: false,
        },
        curl: `curl -s -X POST http://HOST:3000/organize/deduplicate \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed","mediaType":"image","dryRun":false}'`,
      },
      "videos only": {
        body: {
          sourceDir: "/media/input",
          outputDir: "/media/processed",
          mediaType: "video",
          dryRun: false,
        },
        curl: `curl -s -X POST http://HOST:3000/organize/deduplicate \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed","mediaType":"video","dryRun":false}'`,
      },
    },
    responseSample: {
      operation: "deduplicateOnly",
      duplicates: [
        {
          hash: "d41d8cd98f00b204e9800998ecf8427e",
          original: "/media/input/20260101_083000.jpg",
          duplicate: "/media/input/20260101_083000_copy.jpg",
        },
      ],
    },
    errorCodes: { 422: "Missing fields or invalid mediaType" },
  },
];

// ── Section 10 — Validation Error Reference ───────────────────────────────────

const validationReference = {
  description:
    "All POST /organize/* endpoints validate their body with Zod. " +
    "Invalid payloads return HTTP 422 with a structured fieldErrors map. " +
    "Malformed JSON (not parseable) returns HTTP 400.",
  httpCodes: {
    400: "Malformed JSON — body could not be parsed",
    404: "Unknown route — check GET /guide for registered paths",
    422: "Validation failed — see details.fieldErrors for which fields are wrong",
    500: "Internal server error — check GET /logs/errors for details",
  },
  errorShape: {
    error: "Validation failed",
    details: {
      formErrors: [],
      fieldErrors: {
        sourceDir: ["Required"],
        outputDir: ["Required"],
        mediaType: ["Invalid enum value. Expected 'image' | 'video' | 'both', received 'audio'"],
        granularity: ["Invalid enum value. Expected 'day' | 'week' | 'month', received 'year'"],
      },
    },
  },
  invalidExamples: [
    {
      label: "missing sourceDir and outputDir",
      body: { mediaType: "both" },
      expectedStatus: 422,
    },
    {
      label: "invalid mediaType",
      body: { sourceDir: "/media/input", outputDir: "/media/processed", mediaType: "audio" },
      expectedStatus: 422,
    },
    {
      label: "invalid granularity",
      body: {
        sourceDir: "/media/input",
        outputDir: "/media/processed",
        mediaType: "both",
        granularity: "year",
      },
      expectedStatus: 422,
    },
    {
      label: "malformed JSON",
      rawBody: "not-valid-json",
      expectedStatus: 400,
    },
    {
      label: "unknown route",
      method: "GET",
      path: "/logs",
      expectedStatus: 404,
    },
  ],
};

// ── Section 11 — Recommended Workflow ────────────────────────────────────────

const recommendedWorkflow = {
  description:
    "Suggested step-by-step approach when processing a new media directory for the first time.",
  steps: [
    {
      step: 1,
      action: "Check the server is alive",
      curl: "curl http://HOST:3000/",
      expect: '{ "status": "ok" }',
    },
    {
      step: 2,
      action: "Get today's date keys — useful when building date-based payloads",
      curl: "curl http://HOST:3000/calendar",
      expect: "weekKey, monthKey, dayKey values for use in /organize/date",
    },
    {
      step: 3,
      action: "Scan the directory — understand what you have before moving anything",
      curl: `curl -s -X POST http://HOST:3000/organize/scan \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","mediaType":"both"}'`,
      expect: "totalFiles, totalBytesHuman, duplicate count",
    },
    {
      step: 4,
      action: "Dry-run your chosen operation to preview the groups",
      curl: `curl -s -X POST http://HOST:3000/organize/date \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed","mediaType":"both","granularity":"day","dryRun":true}'`,
      expect: "groups[] array showing what would be created — no files moved",
    },
    {
      step: 5,
      action: "Commit — re-run with dryRun: false",
      curl: "Same payload as step 4, change \"dryRun\": false",
      expect: "groups[] with actual moved files and emptyDirsRemoved count",
    },
    {
      step: 6,
      action: "Confirm via logs",
      curl: `curl "http://HOST:3000/logs/recent?lines=30"`,
      expect: "MOVE entries confirming each file's destination",
    },
    {
      step: 7,
      action: "Isolate any remaining duplicates",
      curl: `curl -s -X POST http://HOST:3000/organize/deduplicate \\
  -H "Content-Type: application/json" \\
  -d '{"sourceDir":"/media/input","outputDir":"/media/processed","mediaType":"both","dryRun":false}'`,
      expect: "duplicates[] array listing original vs duplicate paths",
    },
  ],
};

// ── Section 12 — Quick Reference Card ────────────────────────────────────────

const quickReference = {
  title: "All endpoints at a glance",
  fieldValues: {
    mediaType: ["image", "video", "both"],
    granularity: ["day", "week", "month"],
    dryRun: "true = preview only (default false)",
  },
  outputFolderPatterns: {
    filename: "{YYYYMMDD_HHMMSS}__{count}_{size}",
    day: "{YYYYMMDD}__{count}_{size}",
    week: "{YYYY_WNN}__{count}_{size}",
    month: "{YYYYMM}__{count}_{size}",
    hour: "{YYYYMMDD_HH}__{count}_{size}",
  },
  endpoints: [
    { method: "GET",  path: "/",                     movesFiles: false, keyFields: "—" },
    { method: "GET",  path: "/help",                 movesFiles: false, keyFields: "—" },
    { method: "GET",  path: "/guide",                movesFiles: false, keyFields: "—" },
    { method: "GET",  path: "/calendar",             movesFiles: false, keyFields: "—" },
    { method: "GET",  path: "/logs/recent?lines=N",  movesFiles: false, keyFields: "query: lines" },
    { method: "GET",  path: "/logs/errors?lines=N",  movesFiles: false, keyFields: "query: lines" },
    { method: "POST", path: "/organize/scan",        movesFiles: false, keyFields: "sourceDir, mediaType" },
    { method: "POST", path: "/organize/filename",    movesFiles: true,  keyFields: "sourceDir, outputDir, mediaType, dryRun" },
    { method: "POST", path: "/organize/date",        movesFiles: true,  keyFields: "sourceDir, outputDir, mediaType, granularity, dryRun" },
    { method: "POST", path: "/organize/hour",        movesFiles: true,  keyFields: "sourceDir, outputDir, mediaType, dryRun" },
    { method: "POST", path: "/organize/flatten",     movesFiles: true,  keyFields: "sourceDir, outputDir, mediaType, dryRun" },
    { method: "POST", path: "/organize/separate",    movesFiles: true,  keyFields: "sourceDir, outputDir, dryRun" },
    { method: "POST", path: "/organize/related",     movesFiles: true,  keyFields: "sourceDir, outputDir, dryRun" },
    { method: "POST", path: "/organize/deduplicate", movesFiles: true,  keyFields: "sourceDir, outputDir, mediaType, dryRun" },
  ],
};

// ── Assemble full guide ───────────────────────────────────────────────────────

const FULL_GUIDE = {
  title: "Media Organizer API — Consumer Guide & Reference",
  version: "1.0.0",
  description:
    "Complete reference for every endpoint. Includes required fields, " +
    "curl examples, response shapes, validation behaviour, and a recommended workflow.",
  sections: {
    "1_system_and_utility": {
      title: "System & Utility Endpoints",
      endpoints: systemEndpoints,
    },
    "2_scan": {
      title: "Scan — Read-Only Inventory (No File Moves)",
      endpoints: scanEndpoints,
    },
    "3_group_by_filename": {
      title: "Group by Filename Timestamp",
      endpoints: filenameEndpoints,
    },
    "4_group_by_date": {
      title: "Group by Date (Day / Week / Month)",
      endpoints: dateEndpoints,
    },
    "5_group_by_hour": {
      title: "Group by Hour",
      endpoints: hourEndpoints,
    },
    "6_flatten": {
      title: "Flatten — Consolidate to Single Directory",
      endpoints: flattenEndpoints,
    },
    "7_separate_by_type": {
      title: "Separate by Type — Split Images and Videos",
      endpoints: separateEndpoints,
    },
    "8_related_content": {
      title: "Related Content — Same-Timestamp Image + Video Pairs",
      endpoints: relatedEndpoints,
    },
    "9_deduplicate": {
      title: "Deduplicate — MD5-Based Duplicate Removal",
      endpoints: deduplicateEndpoints,
    },
    "10_validation_errors": {
      title: "Validation Behaviour & Error Reference",
      ...validationReference,
    },
    "11_recommended_workflow": {
      title: "Recommended Workflow for a New Media Directory",
      ...recommendedWorkflow,
    },
    "12_quick_reference": {
      ...quickReference,
    },
  },
  notes: [
    "All POST /organize/* endpoints accept a JSON body.",
    "dryRun: true previews the operation — no files are moved. Always try this first.",
    "mediaType controls which files are processed: 'image' | 'video' | 'both'.",
    "Duplicates are detected by MD5 hash and routed to a .duplicates/ subfolder automatically.",
    "Empty source directories are cleaned up after each operation.",
    "Use GET /calendar to retrieve weekKey / monthKey / dayKey before date operations.",
    "Use GET /logs/recent and GET /logs/errors to audit what happened after a run.",
    "Pipe this guide through jq for readable output: curl -s http://HOST:3000/guide | jq",
  ],
};

// ── Route ─────────────────────────────────────────────────────────────────────

apiGuide.get("/", (c) => {
  return c.json({
    ...FULL_GUIDE,
    generatedAt: new Date().toISOString(),
  });
});

export default apiGuide;
