#!/usr/bin/env bats
# Unit-тесты списка БД: valid_db_name, is_excluded, get_database_list.
#
# Чистые функции (valid_db_name, is_excluded) — без shim'ов.
# Автоопрос (get_database_list) — через psql-shim:
#   SHIM_PSQL_LIST  — многострочный список имён (ответ сервера)
#   SHIM_PSQL_FAIL  — сбой подключения
#
# DBS_TO_BACKUP — глобальный массив, заполняется get_database_list.

load '../helpers/bats-helpers'

# --- valid_db_name ----------------------------------------------------------

@test "valid_db_name: корректное имя" {
  source_script
  valid_db_name "orders"
}

@test "valid_db_name: имя с дефисом и подчёркиванием" {
  source_script
  valid_db_name "my-db_1"
}

@test "valid_db_name: имя с пробелом — некорректно" {
  source_script
  local rc=0
  valid_db_name "my db" || rc=$?
  [[ "$rc" -ne 0 ]]
}

@test "valid_db_name: пустое имя — некорректно" {
  source_script
  local rc=0
  valid_db_name "" || rc=$?
  [[ "$rc" -ne 0 ]]
}

# --- is_excluded ------------------------------------------------------------

@test "is_excluded: имя в списке исключений" {
  source_script
  EXCLUDE_DBS="template0 template1"
  is_excluded "template1"
}

@test "is_excluded: имя не в списке" {
  source_script
  EXCLUDE_DBS="template0 template1"
  local rc=0
  is_excluded "orders" || rc=$?
  [[ "$rc" -ne 0 ]]
}

@test "is_excluded: пустой список исключений" {
  source_script
  EXCLUDE_DBS=""
  local rc=0
  is_excluded "orders" || rc=$?
  [[ "$rc" -ne 0 ]]
}

# --- get_database_list: явный список ----------------------------------------

@test "get_database_list: явный список валидных баз" {
  source_script
  DB_LIST="orders users logs"
  local rc=0
  get_database_list >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]]
  [[ "${#DBS_TO_BACKUP[@]}" -eq 3 ]]
  [[ "${DBS_TO_BACKUP[0]}" == "orders" ]]
}

@test "get_database_list: некорректное имя в DB_LIST" {
  source_script
  DB_LIST="orders my.db"  # точка вне [A-Za-z0-9_-]
  local rc=0
  get_database_list >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 2 ]]
}

@test "get_database_list: исключение применяется" {
  source_script
  DB_LIST="orders users"
  EXCLUDE_DBS="users"
  local rc=0
  get_database_list >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]]
  [[ "${#DBS_TO_BACKUP[@]}" -eq 1 ]]
  [[ "${DBS_TO_BACKUP[0]}" == "orders" ]]
}

@test "get_database_list: дубликаты убираются" {
  source_script
  DB_LIST="orders orders users"
  local rc=0
  get_database_list >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]]
  [[ "${#DBS_TO_BACKUP[@]}" -eq 2 ]]
}

@test "get_database_list: все исключены — нет баз" {
  source_script
  DB_LIST="template1"
  local rc=0
  get_database_list >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 3 ]]
}

# --- get_database_list: автоопрос -------------------------------------------

@test "get_database_list: автоопрос возвращает базы" {
  source_script
  PATH="$SHIMS:$PATH"
  export SHIM_PSQL_LIST="orders users logs"  # пробельный разделитель (см. shim)
  local rc=0
  get_database_list >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]]
  [[ "${#DBS_TO_BACKUP[@]}" -eq 3 ]]
}

@test "get_database_list: автоопрос — сбой psql" {
  source_script
  PATH="$SHIMS:$PATH"
  export SHIM_PSQL_FAIL=1
  local rc=0
  get_database_list >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 2 ]]
}

@test "get_database_list: автоопрос — все исключены" {
  source_script
  PATH="$SHIMS:$PATH"
  export SHIM_PSQL_LIST="template0 template1"
  local rc=0
  get_database_list >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 3 ]]
}
