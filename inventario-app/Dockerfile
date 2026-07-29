# =============================================================================
# Dockerfile multi-stage — Instrucciones.html: Paso 2
# =============================================================================
# Etapa 1: builder — instala dependencias y ejecuta npm test.
#   El build FALLA si npm test falla (fail-fast).
# Etapa 2: runtime — imagen mínima de producción.
#   Copia solo lo necesario: node_modules, public/, server.js, db.js, data/.
#   No incluye package-lock.json innecesarios, node_modules de dev, etc.
# =============================================================================

FROM node:18-alpine3.21 AS builder

WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm test

FROM node:18-alpine3.21 AS runtime

WORKDIR /app
RUN apk --no-cache upgrade && rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx && addgroup -g 1001 -S nodejs && adduser -S nodejs -u 1001

COPY --from=builder --chown=nodejs:nodejs /app/node_modules ./node_modules
COPY --from=builder --chown=nodejs:nodejs /app/package*.json ./
COPY --from=builder --chown=nodejs:nodejs /app/public ./public
COPY --from=builder --chown=nodejs:nodejs /app/db.js ./
COPY --from=builder --chown=nodejs:nodejs /app/server.js ./
COPY --from=builder --chown=nodejs:nodejs /app/data ./data

USER nodejs
EXPOSE 3000
CMD ["node", "server.js"]
