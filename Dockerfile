FROM node:18-alpine

WORKDIR /app

# Установим зависимости системы, если нужно
RUN apk add --no-cache python3 make g++ bash

COPY package.json yarn.lock* ./

# Установка зависимостей:
# - если есть yarn.lock — используем yarn
# - если есть package-lock.json — используем npm ci
# - иначе — обычный npm install (создаст lockfile внутри сборки)
RUN if [ -f yarn.lock ]; then \
      npm i -g yarn && yarn install --frozen-lockfile; \
    elif [ -f package-lock.json ]; then \
      npm ci; \
    else \
      npm install; \
    fi

COPY . .

ENV NODE_ENV=production
EXPOSE 14127

CMD ["node", "src/app.js"]
