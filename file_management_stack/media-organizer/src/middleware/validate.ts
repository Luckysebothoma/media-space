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
