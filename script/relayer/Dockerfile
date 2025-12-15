FROM node:18-alpine AS builder

WORKDIR /app

# Copy package files
COPY package*.json ./
COPY tsconfig.json ./

# Install dependencies
RUN npm ci

# Copy source
COPY src ./src

# Build
RUN npm run build

# Production image
FROM node:18-alpine

WORKDIR /app

# Copy package files
COPY package*.json ./

# Install production dependencies only
RUN npm ci --production

# Copy built files
COPY --from=builder /app/dist ./dist

# Create volume for database
VOLUME ["/app/data"]

# Expose metrics port
EXPOSE 9090
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
  CMD node -e "require('http').get('http://localhost:8080/health', (r) => { process.exit(r.statusCode === 200 ? 0 : 1); })"

# Run as non-root user
USER node

CMD ["node", "dist/index.js"]
