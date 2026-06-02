# syntax=docker/dockerfile:1.7

# ---- 第 1 阶段：安装依赖 ----
FROM node:24-alpine AS deps

ENV PNPM_HOME=/pnpm
ENV PATH=$PNPM_HOME:$PATH

# 固定 pnpm 版本，避免每次 prepare latest 产生不可预期变化
RUN corepack enable && corepack prepare pnpm@10.14.0 --activate

WORKDIR /app

# 仅复制依赖清单，提高构建缓存利用率
COPY package.json pnpm-lock.yaml ./

# 使用 BuildKit cache 复用 pnpm store，依赖层失效时也能快速重装
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
  pnpm config set store-dir /pnpm/store \
  && pnpm install --frozen-lockfile --prefer-offline

# ---- 第 2 阶段：构建项目 ----
FROM node:24-alpine AS builder

ENV PNPM_HOME=/pnpm
ENV PATH=$PNPM_HOME:$PATH

RUN corepack enable && corepack prepare pnpm@10.14.0 --activate
WORKDIR /app

# 复制依赖
COPY --from=deps /app/node_modules ./node_modules
# 复制全部源代码
COPY . .

# 在构建阶段也显式设置 DOCKER_ENV
ENV DOCKER_ENV=true

# 生成生产构建；复用 Next 构建缓存，减少重复打包耗时
RUN --mount=type=cache,id=next-cache,target=/app/.next/cache \
  pnpm run build

# 使用 pnpm deploy 提取生产依赖到独立目录
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
  pnpm config set store-dir /pnpm/store \
  && pnpm deploy --filter=. --prod --legacy /tmp/prod-deps

# ---- 第 3 阶段：生成运行时镜像 ----
FROM node:24-alpine AS runner

# 创建非 root 用户
RUN addgroup -g 1001 -S nodejs && adduser -u 1001 -S nextjs -G nodejs

WORKDIR /app
ENV NODE_ENV=production
ENV HOSTNAME=0.0.0.0
ENV PORT=3000
ENV DOCKER_ENV=true
ENV SQLITE_DB_PATH=/app/.data/moontv.db
ENV OFFLINE_DOWNLOAD_DIR=/data

# 从构建器中复制 standalone 输出
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
# 从构建器中复制 scripts 目录
COPY --from=builder --chown=nextjs:nodejs /app/scripts ./scripts
# 从构建器中复制 migrations 目录
COPY --from=builder --chown=nextjs:nodejs /app/migrations ./migrations
# 从构建器中复制 start.js
COPY --from=builder --chown=nextjs:nodejs /app/start.js ./start.js
# 从构建器中复制自定义 server.js（包含 Socket.IO 支持）
COPY --from=builder --chown=nextjs:nodejs /app/server.js ./server.js
# 自定义 server.js 在运行时会 require('./src/lib/tv-remote-hub.js')。
# Next standalone 只会追踪 Next 应用入口，不会自动包含自定义服务器额外 require 的源文件，
# 因此需要显式复制该运行时模块，避免生产镜像启动时报 Cannot find module。
COPY --from=builder --chown=nextjs:nodejs /app/src/lib/tv-remote-hub.js ./src/lib/tv-remote-hub.js
# 从构建器中复制 public 和 .next/static 目录
COPY --from=builder --chown=nextjs:nodejs /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

# 从构建器中复制生产依赖（包含 Socket.IO / better-sqlite3）
COPY --from=builder --chown=nextjs:nodejs /tmp/prod-deps/node_modules ./node_modules

# 准备 SQLite 数据目录和默认离线下载目录
RUN mkdir -p /app/.data "$OFFLINE_DOWNLOAD_DIR" \
  && chown -R nextjs:nodejs /app/.data "$OFFLINE_DOWNLOAD_DIR"

# 切换到非特权用户
USER nextjs

EXPOSE 3000

# 使用自定义启动脚本，先预加载配置再启动服务器
CMD ["node", "start.js"]
