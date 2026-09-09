#!/usr/bin/env bats
# Unit-тесты pipeline: dump_database, compress_dump, verify_archive,
# move_archive.
#
# Функции импортируются (PG_BACKUP_NO_MAIN) и вызываются в изоляции.
# WORK_DIR_ACTUAL и BACKUP_DIR задаются в каждом тесте.
# Внешние команды — shim'ы (pg_dump, gzip, df, date) + реальные (gzip -t, mv).
#
# Shim-переменные:
#   SHIM_PG_DUMP_FAIL / SHIM_PG_DUMP_TRUNCATE — сценарии pg_dump
#   SHIM_GZIP_FAIL                            — сбой сжатия
#   SHIM_DF_MB                                — фиксированное свободное место
#   SHIM_DATE_STAMP                           — фиксированная метка времени

load '../helpers/bats-helpers'

# Общий setup: рабочая директория
setup_work() {
  WORK_DIR_ACTUAL="$TEST_DIR/work"
  mkdir -p "$WORK_DIR_ACTUAL"
}

# --- dump_database ----------------------------------------------------------

@test "dump_database: успех" {
  source_script
  PATH="$SHIMS:$PATH"
  setup_work
  local rc=0
  dump_database "orders" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]]
  [[ -s "$WORK_DIR_ACTUAL/orders.sql" ]]
}

@test "dump_database: сбой pg_dump" {
  source_script
  PATH="$SHIMS:$PATH"
  export SHIM_PG_DUMP_FAIL=1
  setup_work
  local rc=0
  dump_database "orders" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]]
  [[ ! -e "$WORK_DIR_ACTUAL/orders.sql" ]]
  [[ ! -e "$WORK_DIR_ACTUAL/orders.dump.err" ]]
}

@test "dump_database: неполный дамп (нет маркера)" {
  source_script
  PATH="$SHIMS:$PATH"
  export SHIM_PG_DUMP_TRUNCATE=1
  setup_work
  local rc=0
  dump_database "orders" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]]
  [[ ! -e "$WORK_DIR_ACTUAL/orders.sql" ]]
}

# --- compress_dump ----------------------------------------------------------

@test "compress_dump: успех" {
  source_script
  PATH="$SHIMS:$PATH"
  setup_work
  echo "data" > "$WORK_DIR_ACTUAL/orders.sql"
  local rc=0
  compress_dump "orders" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]]
  [[ -s "$WORK_DIR_ACTUAL/orders.sql.gz" ]]
  [[ ! -e "$WORK_DIR_ACTUAL/orders.sql" ]]
}

@test "compress_dump: сбой gzip" {
  source_script
  PATH="$SHIMS:$PATH"
  export SHIM_GZIP_FAIL=1
  setup_work
  echo "data" > "$WORK_DIR_ACTUAL/orders.sql"
  local rc=0
  compress_dump "orders" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]]
  [[ ! -e "$WORK_DIR_ACTUAL/orders.sql" ]]
  [[ ! -e "$WORK_DIR_ACTUAL/orders.sql.gz" ]]
}

@test "compress_dump: нет дампа" {
  source_script
  PATH="$SHIMS:$PATH"
  setup_work
  local rc=0
  compress_dump "orders" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]]
}

# --- verify_archive ---------------------------------------------------------

@test "verify_archive: целостность OK" {
  source_script
  PATH="$SHIMS:$PATH"
  setup_work
  echo "data" | gzip > "$WORK_DIR_ACTUAL/orders.sql.gz"
  local rc=0
  verify_archive "orders" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]]
}

@test "verify_archive: битый архив" {
  source_script
  PATH="$SHIMS:$PATH"
  setup_work
  echo "junk" > "$WORK_DIR_ACTUAL/orders.sql.gz"
  local rc=0
  verify_archive "orders" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]]
  [[ ! -e "$WORK_DIR_ACTUAL/orders.sql.gz" ]]
}

@test "verify_archive: нет архива" {
  source_script
  PATH="$SHIMS:$PATH"
  setup_work
  local rc=0
  verify_archive "orders" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]]
}

# --- move_archive -----------------------------------------------------------

setup_move() {
  setup_work
  BACKUP_DIR="$TEST_DIR/bk"
  mkdir -p "$BACKUP_DIR"
}

@test "move_archive: успешный перенос" {
  source_script
  PATH="$SHIMS:$PATH"
  setup_move
  echo "data" | gzip > "$WORK_DIR_ACTUAL/orders.sql.gz"
  local rc=0
  move_archive "orders" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]]
  [[ ! -e "$WORK_DIR_ACTUAL/orders.sql.gz" ]]
  ls "$BACKUP_DIR"/orders_*.sql.gz >/dev/null 2>&1
}

@test "move_archive: мало места на целевом диске" {
  source_script
  PATH="$SHIMS:$PATH"
  export SHIM_DF_MB=0
  setup_move
  echo "data" | gzip > "$WORK_DIR_ACTUAL/orders.sql.gz"
  local rc=0
  move_archive "orders" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]]
  [[ ! -e "$WORK_DIR_ACTUAL/orders.sql.gz" ]]
}

@test "move_archive: коллизия имён — суффикс" {
  source_script
  PATH="$SHIMS:$PATH"
  export SHIM_DATE_STAMP="20260101-000000"
  setup_move
  echo "data" | gzip > "$WORK_DIR_ACTUAL/orders.sql.gz"
  # Существующий архив с тем же именем
  touch "$BACKUP_DIR/orders_20260101-000000.sql.gz"
  local rc=0
  move_archive "orders" >/dev/null 2>&1 || rc=$?
  # Новое поведение: коллизия разрешается суффиксом -1
  [[ "$rc" -eq 0 ]]
  [[ ! -e "$WORK_DIR_ACTUAL/orders.sql.gz" ]]
  [[ -e "$BACKUP_DIR/orders_20260101-000000-1.sql.gz" ]]
}

@test "move_archive: нет архива" {
  source_script
  PATH="$SHIMS:$PATH"
  setup_move
  local rc=0
  move_archive "orders" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]]
}
