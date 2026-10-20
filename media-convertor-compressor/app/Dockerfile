FROM node:22-slim

RUN apt-get update && apt-get install -y \
    ffmpeg \
    imagemagick \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json ./

RUN npm install

COPY src ./src
USER root

CMD ["node", "src/index.js"]
