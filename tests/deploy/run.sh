#!/usr/bin/env bash
# Оркестратор deploy-теста: прогоняет инструкции из docs/DEPLOYMENT.md
# в чистом Ubuntu-контейнере. На хосте требуется только docker.
#
# Использование:
#   bash tests/deploy/run.sh
#
# Переменные:
#   DEPLOY_IMAGE     имя образа (по умолчанию pg-backup-deploy)
#   DEPLOY_CONTAINER имя контейнера (по умолчанию pg-backup-deploy)
set -euo pipefail

IMAGE="${DEPLOY_IMAGE:-pg-backup-deploy}"
CONTAINER="${DEPLOY_CONTAINER:-pg-backup-deploy}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

log() { printf '[deploy-test] %s\n' "$*" >&2; }

# При успехе контейнер убираем, при сбое оставляем для отладки
# shellcheck disable=SC2317  # вызывается через trap cleanup EXIT
cleanup() {
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  else
    log "тест завершился с ошибкой — контейнер $CONTAINER сохранён для отладки"
    log "   docker exec -it $CONTAINER bash"
  fi
}
trap cleanup EXIT

# 1. Образ: собираем только если его ещё нет
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  log "собираю образ $IMAGE"
  docker build -t "$IMAGE" \
    -f "$REPO_ROOT/tests/deploy/Dockerfile.deploy" "$REPO_ROOT/tests/deploy"
fi

# 2. Свежий контейнер
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" "$IMAGE" >/dev/null

# 3. Ожидание готовности: сервер отвечает И тестовые данные созданы
ready=0
for _ in $(seq 1 60); do
  if docker exec "$CONTAINER" sudo -u postgres psql -d orders -tAc \
    "SELECT count(*) FROM orders" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [[ $ready -ne 1 ]]; then
  log "ОШИБКА: PostgreSQL не готов или тестовые данные не созданы"
  docker logs "$CONTAINER" >&2 || true
  exit 1
fi
log "PostgreSQL готов, тестовые данные на месте"

# 4. Копируем репозиторий в контейнер
docker cp "$REPO_ROOT" "$CONTAINER:/tmp/repo"

# 5. Тест
docker exec "$CONTAINER" bash -c 'cd /tmp/repo && bash tests/deploy/test-deploy.sh'
