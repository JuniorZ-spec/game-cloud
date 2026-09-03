# Rebuild post-teardown (nouveau cluster) - 20260903T155134
FROM node:20-alpine

WORKDIR /app

COPY package.json .
RUN npm install --omit=dev

COPY server.js .

RUN addgroup -S app && adduser -S app -G app
USER app

EXPOSE 3003

CMD ["node", "server.js"]
