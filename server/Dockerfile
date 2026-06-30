# flutter_patcher reference server — container image (works on Railway, Fly, etc.)
FROM node:22-alpine

WORKDIR /app

# Install runtime deps first for layer caching. tsx is a runtime dep (we run TS
# directly via esbuild), so we keep prod deps only.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY . .

# Patches + the JSON store live here. Mount a persistent volume at /data on the
# host (Railway: add a Volume mounted at /data) or state resets on each deploy.
ENV FP_DATA_DIR=/data
RUN mkdir -p /data

# Railway/most PaaS inject PORT; the server reads process.env.PORT (default 8090).
EXPOSE 8090

# FP_SIGNING_SEED MUST be provided at runtime (Railway → Variables). Generate one
# with: docker run --rm <image> npm run keygen
CMD ["npm", "start"]
