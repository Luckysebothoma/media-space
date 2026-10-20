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
