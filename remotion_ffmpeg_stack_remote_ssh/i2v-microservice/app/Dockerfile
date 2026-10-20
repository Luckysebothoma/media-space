FROM node:22-slim

# ffmpeg          -> rendering
# openssh-client   -> ssh transport
# sshfs            -> mount remote SSH sources
# sshpass          -> password-based sshfs (key auth preferred)
# cifs-utils       -> mount SMB/CIFS sources
# fuse3            -> user-space mount support for sshfs
RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    openssh-client \
    sshfs \
    sshpass \
    cifs-utils \
    fuse3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json ./
RUN npm install --omit=dev

COPY src ./src

RUN mkdir -p /data/media /data/archives /data/logs /data/remote \
             /data/secrets/ssh-keys /data/secrets/smb-creds

EXPOSE 3000

# Runs as root: required for mount/mount.cifs and sshfs with allow_other.
CMD ["node", "src/index.js"]
