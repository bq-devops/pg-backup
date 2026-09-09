#!/usr/bin/env bats
# Unit-тесты цикла: backup_one_db (цепочка) и основной цикл
# (изоляция сбоев, счётчики, exit code).
#
# backup_one_db — импорт (source_script) + прямой вызов, сбой на каждом шаге.
# Основной цикл — полный запуск (run_script) с per-DB сбоем;
# проверка exit code и сводки в логе.
#
# Shim-переменные:
#   SHIM_PG_DUMP_FAIL / SHIM_PG_DUMP_FAIL_DBS — сбой дампа (все / выбранные)
#   SHIM_GZIP_FAIL / SHIM_GZIP_CORRUPT        — сбой сжатия / битый архив
#   SHIM_DF_MB                                — фиксированное свободное место

load '../helpers/bats-helpers'

# Общий setup для backup_one_db: рабочая и целевая директории
setup_one_db() {
  WORK_DIR_ACTUAL="$TEST_DIR/work"
  mkdir -p "$WORK_DIR_ACTUAL"
  BACKUP_DIR="$TEST_DIR/bk"
  mkdir -p "$BACKUP_DIR"
}

# --- backup_one_db ----------------------------------------------------------

@test "backup_one_db: успех (вся цепочка)" {
  source_script
  PATH="$SHIMS:$PATH"
  setup_one_db
  export SHIM_DF_MB=1000
  local rc=0
  backup_one_db "orders" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]]
}

@test "backup_one_db: сбой на дампе" {
  source_script
  PATH="$SHIMS:$PATH"
  setup_one_db
  export SHIM_PG_DUMP_FAIL=1
  local rc=0
  backup_one_db "orders" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]]
}

@test "backup_one_db: сбой на сжатии" {
  source_script
  PATH="$SHIMS:$PATH"
  setup_one_db
  export SHIM_GZIP_FAIL=1
  local rc=0
  backup_one_db "orders" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]]
}

@test "backup_one_db: сбой на целостности" {
  source_script
  PATH="$SHIMS:$PATH"
  setup_one_db
  export SHIM_GZIP_CORRUPT=1
  local rc=0
  backup_one_db "orders" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]]
}

@test "backup_one_db: сбой на переносе" {
  source_script
  PATH="$SHIMS:$PATH"
  setup_one_db
  export SHIM_DF_MB=0
  local rc=0
  backup_one_db "orders" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 1 ]]
}

# --- Основной цикл ----------------------------------------------------------

# Общий setup для полного запуска: preflight проходит, задан список баз
setup_full_run() {
  export PATH="$SHIMS:$PATH"
  export DB_LIST="orders users logs"
  export BACKUP_DIR="$TEST_DIR/bk"
  mkdir -p "$BACKUP_DIR"
  export SHIM_DF_MB=1000
}

@test "цикл: все базы скопированы" {
  setup_full_run
  run run_script
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"успешно 3"* ]]
  [[ "$output" == *"сбой 0"* ]]
}

@test "цикл: все базы упали" {
  setup_full_run
  export SHIM_PG_DUMP_FAIL=1
  run run_script
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"успешно 0"* ]]
  [[ "$output" == *"сбой 3"* ]]
}

@test "цикл: 2 из 3 упали (изоляция)" {
  setup_full_run
  export SHIM_PG_DUMP_FAIL_DBS="orders users"
  run run_script
  [[ "$status" -eq 1 ]]
  [[ "$output" == *"успешно 1"* ]]
  [[ "$output" == *"сбой 2"* ]]
  [[ "$output" == *"orders"* ]]
  [[ "$output" == *"users"* ]]
}
