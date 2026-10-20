import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { logger as winstonLogger } from "./utils/logger";
import organizeRouter from "./routes/organize";
import helperRouter from "./routes/helper";
import systemRouter from "./routes/system";
import fs from "fs";
import apiGuide from "./routes/api-guide";
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


app.route("/guide", apiGuide);

import { createMediaOrganizer, MEDIA_CONFIG } from "./services/media-organizer";
const organizer = createMediaOrganizer();
app.route("/v1/", organizer);

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
