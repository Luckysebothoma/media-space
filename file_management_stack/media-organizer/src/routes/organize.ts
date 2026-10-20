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

const organize = new Hono<AppEnv>();

type AppEnv = {
  Variables: {
    validatedBody: unknown;
  };
};

const app = new Hono<AppEnv>();

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
   // const result = await separateByType({ ...body, mediaType: "both" });
   const result = await separateByType(body); 
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
