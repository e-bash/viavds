FROM node:18-alpine

WORKDIR /app

# Установим зависимости системы, если нужно
RUN apk add --no-cache python3 make g++ bash

COPY package.json yarn.lock* ./

# Установка зависимостей (если есть yarn.lock — используем yarn)
RUN if [ -f yarn.lock ]; then npm i -g yarn && yarn install --frozen-lockfile; else npm ci; fi

COPY . .

ENV NODE_ENV=production
EXPOSE 14127

CMD ["node", "src/app.js"]
