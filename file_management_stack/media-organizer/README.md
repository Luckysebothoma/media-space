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
