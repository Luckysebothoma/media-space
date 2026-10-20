FROM ubuntu:22.04

# Avoid interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies (ffmpeg assumed needed)
RUN apt-get update && \
    apt-get install -y \
        ffmpeg \
        bash \
        coreutils \
        findutils \
        && rm -rf /var/lib/apt/lists/*

# Create app dir
WORKDIR /app/

# Copy scripts
COPY run_composer_v3.sh .
COPY start_composing.sh .
#COPY render.sh /app/render.sh

# Make executable
RUN chmod +x /app/run_composer_v3.sh 
RUN chmod +x /app/start_composing.sh
#/app/render.sh

# Create mount points
RUN mkdir -p /app/input /app/output /app/archives

# Default entrypoint

#ENTRYPOINT ["/app/run_composer_v3.sh"]

ENTRYPOINT ["bash", "/app/start_composing.sh"]