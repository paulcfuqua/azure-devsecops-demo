FROM node:20-alpine
WORKDIR /app
COPY . .
RUN npm ci --omit=dev
USER node
EXPOSE 3000
CMD ["node", "src/app.js"]
