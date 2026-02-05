FROM node:20-alpine

WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm install --omit=dev

COPY src ./src
COPY public ./public

ARG YOUR_NAME="RICHARDBARRETT"
# Requirement: image must contain wizexercise.txt and your name
RUN echo "${YOUR_NAME}" > /app/wizexercise.txt

EXPOSE 3000
ENV PORT=3000
CMD ["npm", "start"]
