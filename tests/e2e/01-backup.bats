#!/usr/bin/env bats
# E2E-тесты: реальный PostgreSQL, реальные pg_dump/psql/gzip.
# Проверяем: happy path, изоляцию сбоев, восстановление, нулевой мусор.
#
# Окружение (задаёт tests/run.sh):
#   PGHOST=localhost PGPORT=5432 PGDATABASE=postgres
#   PGUSER=backup PGPASSWORD=backup-only
# backup имеет SELECT на orders/users/logs, но НЕ на restricted.

load '../helpers/bats-helpers'

# Суперпользователь для restore (создание БД, проверка данных)
SU_USER="tester"
SU_PASS="e2e-test-only"

# --- Happy path -------------------------------------------------------------

@test "happy path: все БД скопированы, архивы валидны" {
  export BACKUP_DIR="$TEST_DIR/bk"
  mkdir -p "$BACKUP_DIR"
  export DB_LIST="orders users logs"
  run run_script
  [[ "$status" -eq 0 ]]
  local count
  count="$(ls "$BACKUP_DIR"/*.sql.gz 2>/dev/null | wc -l)"
  [[ "$count" -eq 3 ]]
  local f
  for f in "$BACKUP_DIR"/*.sql.gz; do
    gzip -t "$f"
  done
}

# --- Изоляция сбоев ---------------------------------------------------------

@test "изоляция: restricted упал, остальные скопированы, только валидные" {
  export BACKUP_DIR="$TEST_DIR/bk"
  mkdir -p "$BACKUP_DIR"
  export DB_LIST="orders users logs restricted"
  run run_script
  [[ "$status" -eq 1 ]]
  # 3 архива (orders, users, logs), restricted отсутствует
  local count
  count="$(ls "$BACKUP_DIR"/*.sql.gz 2>/dev/null | wc -l)"
  [[ "$count" -eq 3 ]]
  local f
  for f in "$BACKUP_DIR"/*.sql.gz; do
    gzip -t "$f"
  done
  [[ ! -e "$BACKUP_DIR"/restricted_*.sql.gz ]]
  # в логе есть упоминание упавшей базы
  [[ "$output" == *"restricted"* ]]
}

# --- Восстановление ---------------------------------------------------------

@test "restore: данные восстановлены" {
  export BACKUP_DIR="$TEST_DIR/bk"
  mkdir -p "$BACKUP_DIR"
  export DB_LIST="orders"
  run run_script
  [[ "$status" -eq 0 ]]
  local archive
  archive="$(ls "$BACKUP_DIR"/orders_*.sql.gz)"

  # Чистая БД для восстановления (суперпользователь).
  # DROP и CREATE — отдельными -c: DROP DATABASE не может идти в транзакции.
  run env PGPASSWORD="$SU_PASS" psql -U "$SU_USER" -d postgres \
    -c "DROP DATABASE IF EXISTS orders_restore"
  run env PGPASSWORD="$SU_PASS" psql -U "$SU_USER" -d postgres \
    -c "CREATE DATABASE orders_restore"
  [[ "$status" -eq 0 ]]

  # Восстановление: plain-дамп -> gunzip -> psql
  run env PGPASSWORD="$SU_PASS" bash -c \
    "gunzip -c '$archive' | psql -U $SU_USER -d orders_restore -q -v ON_ERROR_STOP=1"
  [[ "$status" -eq 0 ]]

  # 5 строк, как в исходнике
  run env PGPASSWORD="$SU_PASS" psql -U "$SU_USER" -d orders_restore \
    -tAc "SELECT count(*) FROM orders"
  [[ "$output" == "5" ]]

  # Конкретное значение сохранено
  run env PGPASSWORD="$SU_PASS" psql -U "$SU_USER" -d orders_restore \
    -tAc "SELECT total FROM orders WHERE customer='Алиса'"
  [[ "$output" == "1500.00" ]]
}

# --- Нулевой мусор ----------------------------------------------------------

@test "нулевой мусор: рабочий каталог очищен" {
  export BACKUP_DIR="$TEST_DIR/bk"
  mkdir -p "$BACKUP_DIR"
  export DB_LIST="orders users logs"
  export WORK_DIR="$TEST_DIR/work"
  mkdir -p "$WORK_DIR"
  run run_script
  [[ "$status" -eq 0 ]]
  # Рабочий каталог (создан нами) очищен от содержимого
  [[ -z "$(ls -A "$WORK_DIR")" ]]
}
