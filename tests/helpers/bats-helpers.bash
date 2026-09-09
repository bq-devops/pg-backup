# Общие функции для bats-тестов.
# Подключается из тестов: load '../helpers/bats-helpers'
#
# Путь к скрипту вычисляется относительно расположения тестов,
# поэтому работает и в контейнере (/tmp/repo), и в CI (checkout).

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"
  SCRIPT="$REPO_ROOT/scripts/pg-backup.sh"
  # shellcheck disable=SC2034  # используется тестами preflight/pipeline (4.3+), не всеми
  SHIMS="$REPO_ROOT/tests/helpers/shims"
  TEST_DIR="$(mktemp -d)"
  # Примечание: переменные подключения (PG*) НЕ сбрасываем здесь —
  # e2e-тестам они нужны для подключения к серверу. Unit-тесты запускаются
  # в чистом окружении (run.sh не передаёт PG* в unit-прогон), а значения
  # из конфига проверяются после load_config_file, который их перезаписывает.
}

teardown() {
  if [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]]; then
    find "$TEST_DIR" -mindepth 1 -delete 2>/dev/null || true
    rmdir -- "$TEST_DIR" 2>/dev/null || true
  fi
}

# Полный запуск скрипта как отдельного процесса (тесты аргументов, ранние выходы)
run_script() {
  bash "$SCRIPT" "$@"
}

# Импорт функций скрипта без запуска main (тесты отдельных функций)
source_script() {
  # shellcheck source=/dev/null  # путь к скрипту вычисляется в рантайме
  PG_BACKUP_NO_MAIN=1 source "$SCRIPT"
}

# Запись файла конфигурации: write_config <файл> <строка> [строка...]
write_config() {
  local file="$1"
  shift
  printf '%s\n' "$@" >"$file"
}
