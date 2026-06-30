# Root Dockerfile so Railway (or any PaaS) can build the reference server WITHOUT
# changing the service "Root Directory". Build context = repo root; we copy only
# the server/ subdir. (If you instead set Railway's Root Directory to `server`,
# it uses server/Dockerfile — both work.)
FROM node:22-alpine

WORKDIR /app

# Install runtime deps first for layer caching. tsx runs the TS at runtime.
COPY server/package.json server/package-lock.json ./
RUN npm ci --omit=dev

# App source.
COPY server/ ./

# Patches + JSON store live here. Mount a persistent volume at /data (Railway:
# add a Volume mounted at /data) or state resets on each deploy.
ENV FP_DATA_DIR=/data
RUN mkdir -p /data

# Railway/most PaaS inject PORT; the server reads process.env.PORT (default 8090).
EXPOSE 8090

# FP_SIGNING_SEED must be set at runtime (Railway → Variables). Generate one with:
#   docker run --rm <image> npm run keygen
CMD ["npm", "start"]
