#!/usr/bin/env bash
#
# deploy.sh — деплой текущего состояния проекта на сервер.
#
# Что делает:
#   1. Проверяет локальные файлы и SSH-доступ.
#   2. Устанавливает на сервере недостающие зависимости (docker, docker compose, openssh).
#   3. Синхронизирует исходники с локального ПК (tar по ssh, без rsync/git).
#   4. Собирает образ и запускает стек на порту 3000.
#   5. Ставит systemd-юнит, чтобы проект поднимался вместе с сервером.
#   6. Проверяет, что приложение отвечает по HTTP.
#
# Запуск (из корня проекта):
#   ./deploy.sh
#   REMOTE=myserver PORT=3000 ./deploy.sh
#
set -Eeuo pipefail

# ------------------------------- настройки ---------------------------------
REMOTE="${REMOTE:-myserver}"          # ssh-хост из ~/.ssh/config
APP_PORT="${APP_PORT:-3000}"          # порт, который слушает приложение
APP_NAME="${APP_NAME:-harness-proj1}" # имя compose-проекта/контейнера/сервиса
REMOTE_DIR="${REMOTE_DIR:-/opt/harness_proj1}"
SERVICE_NAME="${SERVICE_NAME:-harness-proj1}"
HEALTH_URL="http://127.0.0.1:${APP_PORT}/healthz"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Цветной вывод
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'; C_RED=$'\033[1;31m'; C_YELLOW=$'\033[1;33m'
else
  C_RESET=''; C_BLUE=''; C_GREEN=''; C_RED=''; C_YELLOW=''
fi
step() { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s  !%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
die()  { printf '%s  ✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

on_error() {
  local line=$1
  printf '\n%sДеплой прерван на строке %s%s\n' "$C_RED" "$line" "$C_RESET" >&2
  printf 'Посмотрите логи на сервере:\n  ssh %s "sudo journalctl -u %s -n 50 --no-pager"\n  ssh %s "sudo docker compose -f %s/docker-compose.yml logs --tail=50"\n' \
    "$REMOTE" "$SERVICE_NAME" "$REMOTE" "$REMOTE_DIR" >&2
}
trap 'on_error $LINENO' ERR

# Один ssh-вызов без интерактивности с пробросом кода возврата.
rsh() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$REMOTE" "$@"; }

# --------------------------- локальные проверки ----------------------------
step "Проверка локальных файлов"
cd "$PROJECT_DIR"
for f in Dockerfile docker-compose.yml nginx.conf index.html deploy/"${SERVICE_NAME}.service"; do
  [[ -f "$f" ]] || die "Отсутствует обязательный файл: $f"
done
ok "Все файлы на месте ($PROJECT_DIR)"

step "Проверка SSH-доступа к $REMOTE"
rsh 'true' || die "Не удаётся подключиться к $REMOTE. Проверьте ~/.ssh/config и ключи."
REMOTE_HOST="$(rsh 'hostname; id -un' | tr '\n' ' ')"
ok "Подключение работает: ${REMOTE_HOST}"
rsh 'sudo -n true' 2>/dev/null || die "На сервере требуется sudo без пароля для пользователя deploy."
ok "sudo доступен без пароля"

# ------------------------ установка зависимостей ---------------------------
step "Проверка зависимостей на сервере"
NEED_INSTALL="$(rsh 'if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then echo YES; else echo NO; fi')"
if [[ "$NEED_INSTALL" == "YES" ]]; then
  info "Устанавливаю docker и docker compose plugin (apt)…"
  rsh 'bash -s' <<'REMOTE_INSTALL'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq ca-certificates curl gnupg tar
if ! command -v docker >/dev/null 2>&1; then
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
sudo systemctl enable --now docker >/dev/null 2>&1 || true
REMOTE_INSTALL
else
  info "docker и docker compose уже установлены"
fi
# Пользователь деплоя должен иметь доступ к docker.sock (без перелогина)
rsh 'if ! docker info >/dev/null 2>&1; then sudo usermod -aG docker "$(id -un)"; fi' || true
DOCKER_VER="$(rsh 'sudo docker version --format "{{.Server.Version}}" 2>/dev/null || echo unknown')"
COMPOSE_VER="$(rsh 'sudo docker compose version --short 2>/dev/null || echo unknown')"
ok "Docker server: ${DOCKER_VER}, compose: ${COMPOSE_VER}"

# --------------------------- синхронизация кода ----------------------------
step "Отправка исходников на сервер"
rsh "sudo mkdir -p '$REMOTE_DIR' && sudo chown \$(id -un):\$(id -gn) '$REMOTE_DIR'"
# tar-стрим: только нужные файлы, без .git/.pi/node_modules, порт подставляется из APP_PORT
tar -cf - \
    --exclude='.git' \
    --exclude='.pi' \
    --exclude='node_modules' \
    --exclude='*.log' \
    --exclude='.DS_Store' \
    --exclude='deploy.sh' \
    Dockerfile docker-compose.yml nginx.conf index.html \
  | rsh "tar -xf - -C '$REMOTE_DIR'"
# Конфиг юнита — отдельно в /etc/systemd/system
rsh "cat > /tmp/${SERVICE_NAME}.service" < deploy/"${SERVICE_NAME}.service"
ok "Исходники в $REMOTE_DIR, юнит передан"

# ----------------------------- сборка и старт ------------------------------
step "Сборка образа и запуск приложения"
rsh "sudo docker compose -f '$REMOTE_DIR/docker-compose.yml' up -d --build --remove-orphans"
ok "Контейнер '$APP_NAME' запущен"

# --------------------------- установка как сервис --------------------------
step "Регистрация сервиса systemd ($SERVICE_NAME)"
rsh "sudo install -m 0644 /tmp/${SERVICE_NAME}.service /etc/systemd/system/${SERVICE_NAME}.service"
rsh "sudo systemctl daemon-reload"
# Имя образа в compose фиксировано, чтобы systemd поднимал тот же контейнер
rsh "sudo systemctl enable ${SERVICE_NAME} >/dev/null 2>&1"
ok "Юнит установлен и включён в автозапуск"

# ------------------------------- проверка ----------------------------------
step "Проверка, что приложение слушает ${APP_PORT} и отвечает"
HEALTH_OK=NO
for i in $(seq 1 20); do
  if rsh "curl -fsS --max-time 3 '$HEALTH_URL' >/dev/null 2>&1"; then HEALTH_OK=YES; break; fi
  sleep 1
done
[[ "$HEALTH_OK" == "YES" ]] || {
  rsh "sudo docker compose -f '$REMOTE_DIR/docker-compose.yml' logs --tail=30" || true
  die "Приложение не отвечает на $HEALTH_URL"
}
LOCAL_LISTEN="$(rsh "ss -ltn 2>/dev/null | grep -c ':${APP_PORT} ' || true")"
[[ "$LOCAL_LISTEN" -gt 0 ]] || die "Порт ${APP_PORT} не открыт на сервере"
ok "HTTP 200 на $HEALTH_URL, порт ${APP_PORT} слушается"

# Перезапуск сервиса, чтобы убедиться, что автозапуск рабочий
step "Проверка автозапуска (systemctl restart)"
rsh "sudo systemctl restart ${SERVICE_NAME}"
for i in $(seq 1 25); do
  if rsh "curl -fsS --max-time 3 '$HEALTH_URL' >/dev/null 2>&1"; then
    ok "Сервис поднялся после restart"
    break
  fi
  [[ $i -eq 25 ]] && die "Сервис не поднялся после restart"
  sleep 1
done

EXTERNAL_IP="$(rsh 'curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk "{print \$1}"')"
printf '\n%sДеплой завершён успешно%s\n' "$C_GREEN" "$C_RESET"
printf '  Приложение:   http://%s:%s/\n' "$EXTERNAL_IP" "$APP_PORT"
printf '  Каталог:      %s на %s\n' "$REMOTE_DIR" "$REMOTE"
printf '  Сервис:       %s.service (enabled, автостарт при загрузке)\n' "$SERVICE_NAME"
printf '  Логи:         ssh %s "sudo journalctl -u %s -f"\n' "$REMOTE" "$SERVICE_NAME"
printf '  Логи nginx:   ssh %s "sudo docker compose -f %s/docker-compose.yml logs -f"\n' "$REMOTE" "$REMOTE_DIR"
