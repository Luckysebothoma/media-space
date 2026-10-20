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

RUN mkdir -p /media/input /media/processed /media/dump /app/logs && \
    chown -R appuser:appgroup /media /app/logs /app /media/dump

USER appuser

ENV PORT=3000
ENV LOG_DIR=/app/logs
ENV NODE_ENV=production

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=5 \
  CMD wget -qO- http://localhost:3000/ || exit 1

CMD ["node", "dist/index.js"]
