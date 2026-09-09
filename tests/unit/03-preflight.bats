#!/usr/bin/env bats
# Unit-тесты preflight: require_commands, check_backup_dir,
# check_free_space, check_db_connection.
#
# Функции импортируются (PG_BACKUP_NO_MAIN) и вызываются в изоляции.
# Внешние команды управляются shim'ами (df, psql) и PATH.
#
# Примечания по окружению контейнера (postgres:16-alpine):
#   - /bin содержит date, df, gzip (busybox), но НЕ psql и pg_dump;
#   - timeout — в /usr/bin;
#   - поэтому PATH=/bin даёт чистый сценарий «не хватает утилит».

load '../helpers/bats-helpers'

# --- require_commands -------------------------------------------------------

@test "require_commands: все утилиты на месте" {
  source_script
  PATH="$SHIMS:$PATH"
  local rc=0
  require_commands >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]]
}

@test "require_commands: не хватает утилит" {
  source_script
  PATH="/bin"  # есть gzip/df, нет pg_dump/psql
  local out rc=0
  out="$(require_commands 2>&1)" || rc=$?
  [[ "$rc" -eq 2 ]]
  [[ "$out" == *"pg_dump"* ]]
}

# --- check_backup_dir -------------------------------------------------------

@test "check_backup_dir: каталог существует и доступен" {
  source_script
  BACKUP_DIR="$TEST_DIR/bk"
  mkdir -p "$BACKUP_DIR"
  local rc=0
  check_backup_dir >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]]
}

@test "check_backup_dir: каталог нет, но создаётся" {
  source_script
  BACKUP_DIR="$TEST_DIR/newbk"
  local rc=0
  check_backup_dir >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]]
  [[ -d "$BACKUP_DIR" ]]
}

@test "check_backup_dir: невозможно создать (родитель — файл)" {
  source_script
  local blocker="$TEST_DIR/blocker"
  touch "$blocker"
  BACKUP_DIR="$blocker/sub"
  local rc=0
  check_backup_dir >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 2 ]]
}

# --- check_free_space -------------------------------------------------------

@test "check_free_space: достаточно места" {
  source_script
  PATH="$SHIMS:$PATH"
  export SHIM_DF_MB=1000
  MIN_FREE_SPACE_MB=512
  BACKUP_DIR="$TEST_DIR/bk"
  mkdir -p "$BACKUP_DIR"
  local rc=0
  check_free_space >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]]
}

@test "check_free_space: мало места" {
  source_script
  PATH="$SHIMS:$PATH"
  export SHIM_DF_MB=100
  MIN_FREE_SPACE_MB=512
  BACKUP_DIR="$TEST_DIR/bk"
  mkdir -p "$BACKUP_DIR"
  local rc=0
  check_free_space >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 2 ]]
}

@test "check_free_space: порог не число" {
  source_script
  MIN_FREE_SPACE_MB=abc
  local rc=0
  check_free_space >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 2 ]]
}

# --- check_db_connection ----------------------------------------------------

@test "check_db_connection: подключение успешно" {
  source_script
  PATH="$SHIMS:$PATH"
  local rc=0
  check_db_connection >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]]
}

@test "check_db_connection: сбой подключения" {
  source_script
  PATH="$SHIMS:$PATH"
  export SHIM_PSQL_FAIL=1
  local out rc=0
  out="$(check_db_connection 2>&1)" || rc=$?
  [[ "$rc" -eq 2 ]]
  [[ "$out" == *"Не удалось подключиться"* ]]
}
