# syntax=docker/dockerfile:1

# Образ для статического сайта: nginx, слушающий порт 3000
FROM nginx:1.27-alpine

LABEL org.opencontainers.image.title="harness_proj1" \
      org.opencontainers.image.description="Hello World static site served by nginx on port 3000"

# Конфиг nginx: слушаем 3000, отдаём /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Исходники текущего приложения
COPY index.html /usr/share/nginx/html/index.html

EXPOSE 3000

# Проверка работоспособности контейнера
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:3000/healthz || exit 1

CMD ["nginx", "-g", "daemon off;"]
