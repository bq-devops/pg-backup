#!/usr/bin/env bats
# Тесты загрузки файла конфигурации (load_config_file).
# Функция импортируется без запуска main (хук PG_BACKUP_NO_MAIN).

load '../helpers/bats-helpers'

@test "файл конфигурации не найден: return 2" {
  source_script
  local rc=0
  load_config_file "$TEST_DIR/nonexistent" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 2 ]]
}

@test "строка без '=': return 2 и понятная ошибка" {
  source_script
  write_config "$TEST_DIR/cfg" "FOO"
  local out rc=0
  out="$(load_config_file "$TEST_DIR/cfg" 2>&1)" || rc=$?
  [[ "$rc" -eq 2 ]]
  [[ "$out" == *"не в формате KEY=VALUE"* ]]
}

@test "неизвестный ключ: return 2 и понятная ошибка" {
  source_script
  write_config "$TEST_DIR/cfg" "BOGUS=1"
  local out rc=0
  out="$(load_config_file "$TEST_DIR/cfg" 2>&1)" || rc=$?
  [[ "$rc" -eq 2 ]]
  [[ "$out" == *"Неизвестный параметр"* ]]
}

@test "инъекция кода в конфиг не исполняется" {
  source_script
  local pwned="$TEST_DIR/pwned"
  write_config "$TEST_DIR/cfg" "PGHOST=\$(touch $pwned)"
  local rc=0
  load_config_file "$TEST_DIR/cfg" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]]
  # PGHOST — литерал из файла, а не результат выполнения команды
  local expected='$(touch '"$pwned"')'
  [[ "$PGHOST" == "$expected" ]]
  # Побочный эффект (создание файла) не должен произойти
  [[ ! -e "$pwned" ]]
}

@test "валидное значение: return 0 и переменная задана" {
  source_script
  write_config "$TEST_DIR/cfg" "PGHOST=1.2.3.4"
  local rc=0
  load_config_file "$TEST_DIR/cfg" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]]
  [[ "$PGHOST" == "1.2.3.4" ]]
}

@test "кавычки вокруг значения снимаются" {
  source_script
  write_config "$TEST_DIR/cfg" 'PGHOST="1.2.3.4"'
  local rc=0
  load_config_file "$TEST_DIR/cfg" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]]
  [[ "$PGHOST" == "1.2.3.4" ]]
}

@test "комментарии и пустые строки пропускаются" {
  source_script
  write_config "$TEST_DIR/cfg" "# комментарий" "" "PGPORT=5433"
  local rc=0
  load_config_file "$TEST_DIR/cfg" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]]
  [[ "$PGPORT" == "5433" ]]
}

@test "пустое значение: return 0 и переменная пуста" {
  source_script
  write_config "$TEST_DIR/cfg" "PGHOST="
  local rc=0
  load_config_file "$TEST_DIR/cfg" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -eq 0 ]]
  [[ -z "$PGHOST" ]]
}
