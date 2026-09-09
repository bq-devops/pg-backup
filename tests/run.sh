#!/usr/bin/env bash
# Оркестратор тестов: bats и PostgreSQL живут в docker-контейнере,
# на хосте требуется только docker.
#
# Использование:
#   bash tests/run.sh            # unit + e2e
#   E2E=0 bash tests/run.sh      # только unit
#
# Переменные:
#   TEST_IMAGE     имя образа (по умолчанию pg-backup-test)
#   TEST_CONTAINER имя контейнера (по умолчанию pg-backup-test)
#   E2E            1 — прогонять e2e (по умолчанию), 0 — пропустить
set -euo pipefail

IMAGE="${TEST_IMAGE:-pg-backup-test}"
CONTAINER="${TEST_CONTAINER:-pg-backup-test}"
E2E="${E2E:-1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '[test] %s\n' "$*" >&2; }

# При успехе контейнер убираем, при сбое оставляем для отладки
# shellcheck disable=SC2317  # вызывается через trap cleanup EXIT
cleanup() {
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  else
    log "тесты завершились с ошибкой — контейнер $CONTAINER сохранён для отладки"
    log "   docker exec -it $CONTAINER bash"
  fi
}
trap cleanup EXIT

# 1. Образ: собираем только если его ещё нет
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  log "собираю образ $IMAGE"
  docker build -t "$IMAGE" -f "$REPO_ROOT/tests/Dockerfile.test" "$REPO_ROOT/tests"
fi

# 2. Свежий контейнер: init-данные создаются при первой инициализации
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" "$IMAGE" >/dev/null

# 3. Ожидание готовности: сервер отвечает И тестовые данные созданы.
#    pg_isready может ответить на временном init-сервере до завершения
#    скриптов инициализации, поэтому ждём, пока тестовая таблица доступна.
ready=0
for _ in $(seq 1 60); do
  if docker exec "$CONTAINER" psql -U tester -d orders -tAc \
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

# 5. Тесты
status=0

log "unit-тесты"
if ! docker exec "$CONTAINER" bash -c 'cd /tmp/repo && bats tests/unit/'; then
  status=1
fi

if [[ "$E2E" == "1" ]]; then
  log "e2e-тесты"
  if ! docker exec \
    -e PGHOST=localhost -e PGPORT=5432 -e PGDATABASE=postgres \
    -e PGUSER=backup -e PGPASSWORD=backup-only \
    "$CONTAINER" bash -c 'cd /tmp/repo && bats tests/e2e/'; then
    status=1
  fi
fi

exit $status
