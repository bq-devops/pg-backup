#!/usr/bin/env bash
#
# pg-backup.sh — резервное копирование баз данных PostgreSQL.
#
# Алгоритм: список БД -> дамп (pg_dump) -> gzip -> проверка целостности
#           -> перенос архива в каталог бэкапов (BACKUP_DIR).
#
# Конфигурация: переменные окружения или файл (--config).
# Подробности: config/pg-backup.conf.example, README.md.

set -u

SCRIPT_VERSION="0.0.1"

# Путь к файлу конфигурации (указывается через --config)
CONFIG_FILE=""

usage() {
  cat <<'EOF'
pg-backup — резервное копирование баз данных PostgreSQL

Использование:
  pg-backup.sh [опции]

Опции:
  --config FILE   файл конфигурации (формат KEY=VALUE, см. config/pg-backup.conf.example)
  --help          эта справка
  --version       версия скрипта

Остальные параметры задаются переменными окружения (см. config/pg-backup.conf.example).
EOF
}

# --- Логирование ---------------------------------------------------------
# Формат: 2026-09-07 18:00:00 [INFO] сообщение
# Сообщения короткие, своими словами: что сделали и чем завершилось.
# Каждый выводимый факт — успех или неудача — фиксируем в лог.

# Журнал: файл + stderr одновременно. Если файл недоступен,
# работаем только со stderr — логирование не должно ронять бэкап.
LOG_FILE="${LOG_FILE-/var/log/pg-backup.log}"
LOG_FD=""

log() {
  local level="$1"
  shift
  local ts line
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  line="$(printf '%s [%s] %s' "$ts" "$level" "$*")"
  if [[ -n "$LOG_FD" ]]; then
    printf '%s\n' "$line" >&"$LOG_FD"
  fi
  printf '%s\n' "$line" >&2
}

info() { log "INFO" "$@"; }
warn() { log "WARN" "$@"; }
error() { log "ERROR" "$@"; }

# Вытаскивает главную строку ошибки из вывода утилиты:
# первую строку с "error" (без учёта регистра), иначе последнюю непустую
extract_reason() {
  local out="$1"
  local line
  line="$(printf '%s\n' "$out" | grep -im1 'error')"
  if [[ -z "$line" ]]; then
    line="$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)"
  fi
  printf '%s' "$line"
}

# --- Конфигурация --------------------------------------------------------
# Все параметры задаются переменными окружения; файл конфигурации (--config)
# имеет приоритет. Дефолты — разумные значения для локального сервера.

# Подключение к PostgreSQL
PGHOST="${PGHOST-127.0.0.1}"
PGPORT="${PGPORT-5432}"
PGUSER="${PGUSER-postgres}"
PGPASSWORD="${PGPASSWORD-}"
PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT-10}"

# Какие базы копировать
DB_LIST="${DB_LIST-}"
EXCLUDE_DBS="${EXCLUDE_DBS-template0 template1}"

# Каталоги и лимиты
BACKUP_DIR="${BACKUP_DIR-/var/backups/pg}"
WORK_DIR="${WORK_DIR-}"
MIN_FREE_SPACE_MB="${MIN_FREE_SPACE_MB-512}"

# psql и pg_dump читают параметры подключения из окружения
export PGHOST PGPORT PGUSER PGPASSWORD PGCONNECT_TIMEOUT

# Белый список параметров, которые разрешено задавать в файле конфигурации.
# Ограничение сознательное: файл не исполняется (нет source),
# поэтому из него нельзя «подмешать» произвольный код.
ALLOWED_CONFIG_KEYS="PGHOST PGPORT PGUSER PGPASSWORD PGCONNECT_TIMEOUT \
DB_LIST EXCLUDE_DBS BACKUP_DIR WORK_DIR MIN_FREE_SPACE_MB LOG_FILE"

# Читает файл конфигурации (KEY=VALUE). Возвращает 2 при любой ошибке.
load_config_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    error "Файл конфигурации не найден: $file"
    return 2
  fi
  if [[ ! -r "$file" ]]; then
    error "Файл конфигурации недоступен для чтения: $file"
    return 2
  fi

  local lineno=0 line key value ok k
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    # Обрезаем пробелы по краям строки
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    # Пустые строки и комментарии пропускаем
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      error "Строка $lineno в $file не в формате KEY=VALUE: $line"
      return 2
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    # Обрезаем пробелы в конце значения
    value="${value%"${value##*[![:space:]]}"}"
    # Снимаем одинарные/двойные кавычки, если значение ими обёрнуто.
    # Важно: глоб * должен быть НЕ в кавычках, иначе он станет литералом.
    if [[ ${#value} -ge 2 ]]; then
      case "$value" in
      '"'*'"')
        value="${value#\"}"
        value="${value%\"}"
        ;;
      \'*\')
        value="${value#\'}"
        value="${value%\'}"
        ;;
      esac
    fi
    # Параметр должен быть из белого списка
    ok=0
    for k in $ALLOWED_CONFIG_KEYS; do
      if [[ "$k" == "$key" ]]; then
        ok=1
        break
      fi
    done
    if [[ $ok -eq 0 ]]; then
      error "Неизвестный параметр в $file (строка $lineno): $key"
      return 2
    fi
    export "$key=$value"
  done <"$file"

  info "Загружен файл конфигурации: $file"
  return 0
}

# --- Preflight: проверка окружения ---------------------------------------
# Перед бэкапом убеждаемся, что всё необходимое на месте. Любой сбой —
# понятная запись в лог и ранний выход (exit 2), бэкап не начинается.

# Все необходимые утилиты должны быть в PATH.
require_commands() {
  local missing=()
  local cmd
  for cmd in pg_dump psql gzip df; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Не найдены утилиты: ${missing[*]}"
    return 2
  fi
  info "Необходимые утилиты на месте"
  return 0
}

# Каталог для готовых архивов должен существовать и быть доступным на запись.
check_backup_dir() {
  if [[ -d "$BACKUP_DIR" ]]; then
    if [[ -w "$BACKUP_DIR" ]]; then
      info "Каталог бэкапов готов: $BACKUP_DIR"
      return 0
    fi
    error "Нет прав на запись в каталог бэкапов: $BACKUP_DIR"
    return 2
  fi
  if mkdir -p -- "$BACKUP_DIR" 2>/dev/null && [[ -w "$BACKUP_DIR" ]]; then
    info "Каталог бэкапов создан: $BACKUP_DIR"
    return 0
  fi
  error "Не могу создать каталог бэкапов: $BACKUP_DIR"
  return 2
}

# Сервер должен быть доступен и принимать наши учётные данные.
# Пароль передаётся через окружение, поэтому в лог он не попадает.
check_db_connection() {
  local tmo="$PGCONNECT_TIMEOUT"
  [[ "$tmo" =~ ^[0-9]+$ ]] || tmo=10

  # psql по умолчанию подключается к БД с именем пользователя —
  # такой базы может не быть, поэтому явно указываем postgres (она всегда есть)
  local out rc
  out="$(timeout "$((tmo + 5))" psql -d "${PGDATABASE:-postgres}" -tAc "SELECT 1" 2>&1)"
  rc=$?
  if [[ $rc -eq 0 ]]; then
    info "Подключение к серверу $PGHOST:$PGPORT (пользователь $PGUSER) установлено"
    return 0
  fi

  local reason
  reason="$(extract_reason "$out")"
  [[ -n "$reason" ]] || reason="код завершения $rc"
  error "Не удалось подключиться к серверу $PGHOST:$PGPORT: $reason"
  return 2
}

# --- Рабочий каталог -------------------------------------------------------

# Фактический рабочий каталог (заполняется в prepare_work_dir)
WORK_DIR_ACTUAL=""
# 1 — каталог создан нами (можно удалить целиком), 0 — предоставлен пользователем
WORK_DIR_OWNED=0

# Готовит каталог для дампов: пользовательский WORK_DIR или авто-временный.
# Существующий пользовательский каталог используем только если он пуст —
# по окончании работы его содержимое удаляется, чужие файлы трогать нельзя.
prepare_work_dir() {
  local dir
  if [[ -n "$WORK_DIR" ]]; then
    dir="$WORK_DIR"
    if [[ -d "$dir" ]]; then
      if [[ -n "$(ls -A -- "$dir" 2>/dev/null)" ]]; then
        error "Рабочий каталог не пуст, отказываюсь его использовать: $dir"
        return 2
      fi
      WORK_DIR_OWNED=0
    else
      if ! mkdir -p -- "$dir" 2>/dev/null; then
        error "Не могу создать рабочий каталог: $dir"
        return 2
      fi
      WORK_DIR_OWNED=1
    fi
  else
    if ! dir="$(mktemp -d "${TMPDIR:-/tmp}/pg-backup.XXXXXX" 2>/dev/null)"; then
      error "Не могу создать временный рабочий каталог"
      return 2
    fi
    WORK_DIR_OWNED=1
  fi
  chmod 700 -- "$dir" 2>/dev/null || true
  WORK_DIR_ACTUAL="$dir"
  info "Рабочий каталог: $dir"
  return 0
}

# Удаляет содержимое рабочего каталога (и сам каталог, если создали его мы).
# Идемпотентна: повторный вызов безопасен.
cleanup_work_dir() {
  [[ -n "$WORK_DIR_ACTUAL" && -d "$WORK_DIR_ACTUAL" ]] || return 0
  if find "$WORK_DIR_ACTUAL" -mindepth 1 -delete 2>/dev/null; then
    if [[ $WORK_DIR_OWNED -eq 1 ]]; then
      rmdir -- "$WORK_DIR_ACTUAL" 2>/dev/null || true
    fi
    info "Рабочий каталог очищен: $WORK_DIR_ACTUAL"
  else
    warn "Не удалось полностью очистить рабочий каталог: $WORK_DIR_ACTUAL"
  fi
}

# Подключает очистку к любому варианту завершения: успех, ошибка, Ctrl-C, kill.
setup_cleanup_trap() {
  trap 'cleanup_work_dir' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# --- Дамп ------------------------------------------------------------------

# Создаёт дамп базы в рабочем каталоге (stdout pg_dump -> файл).
# При любом сбое файл дампа не оставляем — дальше по этой базе не идём.
# Возвращает 0 при успехе, 1 при неудаче.
dump_database() {
  local db="$1"
  local dump_file="$WORK_DIR_ACTUAL/$db.sql"
  local err_file="$WORK_DIR_ACTUAL/$db.dump.err"

  info "База $db: начинаю дамп"
  local rc=0
  pg_dump "$db" >"$dump_file" 2>"$err_file" || rc=$?
  if [[ $rc -ne 0 ]]; then
    local reason
    reason="$(extract_reason "$(cat -- "$err_file" 2>/dev/null)")"
    [[ -n "$reason" ]] || reason="код завершения $rc"
    rm -f -- "$dump_file" "$err_file"
    error "База $db: дамп не удался: $reason"
    return 1
  fi
  rm -f -- "$err_file"

  if [[ ! -s "$dump_file" ]]; then
    rm -f -- "$dump_file"
    error "База $db: файл дампа пуст или отсутствует"
    return 1
  fi

  # Корректный дамп всегда заканчивается этим маркером.
  # Если его нет — дамп неполный (например, оборвалась связь на середине записи).
  if ! tail -5 -- "$dump_file" | grep -q 'PostgreSQL database dump complete'; then
    rm -f -- "$dump_file"
    error "База $db: дамп неполный, маркер завершения отсутствует"
    return 1
  fi

  local size
  size="$(du -h -- "$dump_file" 2>/dev/null | awk '{print $1}')"
  info "База $db: дамп создан${size:+ ($size)}"
  return 0
}

# --- Упаковка ---------------------------------------------------------------

# Сжимает дамп в gzip (gzip сам удаляет исходник при успехе).
# При сбое не оставляет ни дампа, ни архива.
# Возвращает 0 при успехе, 1 при неудаче.
compress_dump() {
  local db="$1"
  local dump_file="$WORK_DIR_ACTUAL/$db.sql"
  local archive="$WORK_DIR_ACTUAL/$db.sql.gz"

  if [[ ! -s "$dump_file" ]]; then
    error "База $db: нечего сжимать, файл дампа отсутствует"
    return 1
  fi

  info "База $db: упаковываю в gzip"
  local rc=0
  gzip -9 -- "$dump_file" || rc=$?
  if [[ $rc -ne 0 ]]; then
    rm -f -- "$dump_file" "$archive"
    error "База $db: упаковка в gzip не удалась"
    return 1
  fi

  if [[ ! -s "$archive" ]]; then
    rm -f -- "$dump_file" "$archive"
    error "База $db: архив пуст или отсутствует"
    return 1
  fi

  local size
  size="$(du -h -- "$archive" 2>/dev/null | awk '{print $1}')"
  info "База $db: архив создан${size:+ ($size)}"
  return 0
}

# --- Целостность -------------------------------------------------------------

# Проверяет целостность архива (gzip -t).
# Битый архив удаляем: сломанный бэкап опаснее, чем его отсутствие.
# Возвращает 0 при успехе, 1 при неудаче.
verify_archive() {
  local db="$1"
  local archive="$WORK_DIR_ACTUAL/$db.sql.gz"

  if [[ ! -s "$archive" ]]; then
    error "База $db: нечего проверять, архив отсутствует"
    return 1
  fi

  info "База $db: проверяю целостность архива"
  local out rc=0
  out="$(gzip -t -- "$archive" 2>&1)" || rc=$?
  if [[ $rc -ne 0 ]]; then
    rm -f -- "$archive"
    local reason
    reason="$(extract_reason "$out")"
    [[ -n "$reason" ]] || reason="код завершения $rc"
    error "База $db: целостность архива не подтверждена: $reason"
    return 1
  fi

  info "База $db: целостность архива подтверждена"
  return 0
}

# --- Перенос -----------------------------------------------------------------

# Переносит архив в каталог бэкапов с именем база_ГГГГММДД-ЧЧММСС.sql.gz.
# Перед переносом повторно проверяет место на целевом диске —
# за время дампа диск мог заполниться.
# При сбое локальный архив не оставляем.
# Возвращает 0 при успехе, 1 при неудаче.
move_archive() {
  local db="$1"
  local archive="$WORK_DIR_ACTUAL/$db.sql.gz"

  if [[ ! -s "$archive" ]]; then
    error "База $db: нечего переносить, архив отсутствует"
    return 1
  fi

  # Место на целевом диске: размер архива плюс запас на метаданные
  local need_mb target_mb
  need_mb=$(($(du -m -- "$archive" 2>/dev/null | awk '{print $1}') + 1))
  target_mb="$(free_mb "$BACKUP_DIR")"
  if [[ -z "$target_mb" ]]; then
    rm -f -- "$archive"
    error "База $db: не удалось определить свободное место: $BACKUP_DIR"
    return 1
  fi
  if [[ $target_mb -lt $need_mb ]]; then
    rm -f -- "$archive"
    error "База $db: на целевом диске мало места: ${target_mb} МБ, нужно ${need_mb} МБ"
    return 1
  fi

  local stamp dest counter
  stamp="$(date '+%Y%m%d-%H%M%S')"
  dest="$BACKUP_DIR/${db}_${stamp}.sql.gz"
  # Если архив с таким именем уже существует (два бэкапа в одну секунду),
  # добавляем суффикс -1, -2, ...
  counter=1
  while [[ -e "$dest" ]]; do
    dest="$BACKUP_DIR/${db}_${stamp}-${counter}.sql.gz"
    counter=$((counter + 1))
  done

  info "База $db: переношу архив в $BACKUP_DIR"
  local rc=0
  mv -- "$archive" "$dest" || rc=$?
  if [[ $rc -ne 0 || ! -s "$dest" ]]; then
    rm -f -- "$archive" "$dest"
    error "База $db: не удалось перенести архив в $BACKUP_DIR"
    return 1
  fi

  info "База $db: архив сохранён: $dest"
  return 0
}

# --- Бэкап одной базы ---------------------------------------------------------

# Полный цикл для одной базы: дамп -> gzip -> целостность -> перенос.
# Сбой на любом шаге останавливает работу только по этой базе
# (временные файлы на каждом шаге убираются), остальные базы не страдают.
# Возвращает 0 при успехе, 1 при неудаче.
backup_one_db() {
  local db="$1"

  dump_database "$db" || return 1
  compress_dump "$db" || return 1
  verify_archive "$db" || return 1
  move_archive "$db" || return 1

  info "База $db: резервное копирование завершено"
  return 0
}

# --- Список баз -----------------------------------------------------------

# Глобальный результат: какие базы будем копировать
DBS_TO_BACKUP=()
# Счётчики для сводки
OK_COUNT=0
FAIL_COUNT=0
FAILED_DBS=()

# Имя входит в список исключений?
is_excluded() {
  local name="$1" ex
  for ex in $EXCLUDE_DBS; do
    if [[ "$ex" == "$name" ]]; then
      return 0
    fi
  done
  return 1
}

# Допустимое имя базы: буквы, цифры, подчёркивание, дефис
valid_db_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

# Определяет список баз: явный (DB_LIST) или автоопрос сервера.
# Применяет исключения, убирает дубликаты, валидирует имена.
# Возвращает 2 при ошибке, 3 — если баз не найдено.
get_database_list() {
  DBS_TO_BACKUP=()
  local candidates=()

  if [[ -n "$DB_LIST" ]]; then
    # Явный список из конфигурации: ошибка имени — ошибка пользователя
    read -r -a candidates <<<"$DB_LIST"
    local name
    for name in "${candidates[@]}"; do
      if ! valid_db_name "$name"; then
        error "Некорректное имя базы в DB_LIST: $name"
        return 2
      fi
    done
    info "Используется явный список баз: ${candidates[*]}"
  else
    # Автоопрос: все подключаемые базы, кроме служебных шаблонов
    local out rc line
    out="$(psql -d "${PGDATABASE:-postgres}" -tA -c "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname" 2>&1)"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      local reason
      reason="$(extract_reason "$out")"
      [[ -n "$reason" ]] || reason="код завершения $rc"
      error "Не удалось получить список баз: $reason"
      return 2
    fi
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if ! valid_db_name "$line"; then
        warn "Пропускаю базу с некорректным именем: $line"
        continue
      fi
      candidates+=("$line")
    done <<<"$out"
  fi

  # Исключения и дубликаты
  local name seen=" "
  for name in "${candidates[@]}"; do
    if is_excluded "$name"; then
      continue
    fi
    case "$seen" in
    *" $name "*) continue ;;
    esac
    seen+="$name "
    DBS_TO_BACKUP+=("$name")
  done

  if [[ ${#DBS_TO_BACKUP[@]} -eq 0 ]]; then
    error "Не найдено ни одной базы для резервного копирования"
    return 3
  fi
  info "Базы для резервного копирования (${#DBS_TO_BACKUP[@]}): ${DBS_TO_BACKUP[*]}"
  return 0
}

# Свободное место в МБ по пути (пусто, если определить не удалось).
free_mb() {
  df -Pk "$1" 2>/dev/null | awk 'NR==2 {print int($4/1024)}'
}

# На рабочем и целевом дисках должно быть не меньше MIN_FREE_SPACE_MB.
check_free_space() {
  if ! [[ "$MIN_FREE_SPACE_MB" =~ ^[0-9]+$ ]]; then
    error "MIN_FREE_SPACE_MB должен быть целым числом, сейчас: $MIN_FREE_SPACE_MB"
    return 2
  fi

  # Рабочий каталог может ещё не существовать — идём вверх до существующего.
  local work_probe="${WORK_DIR-/tmp}"
  while [[ ! -d "$work_probe" ]]; do
    work_probe="$(dirname -- "$work_probe")"
  done

  local work_mb target_mb
  work_mb="$(free_mb "$work_probe")"
  if [[ -z "$work_mb" ]]; then
    error "Не удалось определить свободное место: $work_probe"
    return 2
  fi
  target_mb="$(free_mb "$BACKUP_DIR")"
  if [[ -z "$target_mb" ]]; then
    error "Не удалось определить свободное место: $BACKUP_DIR"
    return 2
  fi

  if [[ $work_mb -lt $MIN_FREE_SPACE_MB || $target_mb -lt $MIN_FREE_SPACE_MB ]]; then
    error "Мало места: рабочий диск ${work_mb} МБ, целевой ${target_mb} МБ, порог ${MIN_FREE_SPACE_MB} МБ"
    return 2
  fi
  info "Свободное место в норме: рабочий диск ${work_mb} МБ, целевой ${target_mb} МБ (порог ${MIN_FREE_SPACE_MB} МБ)"
  return 0
}

# Открывает журнал в режиме дозаписи. Успех — 0, сбой — 1 (с предупреждением).
open_log() {
  if [[ -z "$LOG_FILE" ]]; then
    LOG_FD=""
    return 1
  fi
  local dir can_write=0
  dir="$(dirname -- "$LOG_FILE")"
  # Писать можно, если файл уже существует и доступен,
  # либо каталог доступен (создадим файл).
  if [[ -f "$LOG_FILE" && -w "$LOG_FILE" ]]; then
    can_write=1
  elif [[ -d "$dir" && -w "$dir" ]]; then
    can_write=1
  fi
  # ВАЖНО: без «2>/dev/null» — редиректы exec без команды персистентны
  # и навсегда заглушат stderr всего скрипта.
  if [[ $can_write -eq 1 ]] && exec {LOG_FD}>>"$LOG_FILE"; then
    chmod 600 -- "$LOG_FILE" 2>/dev/null || true
    return 0
  fi
  LOG_FD=""
  warn "Не могу писать в $LOG_FILE, журнал только в stderr"
  return 1
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --help | -h)
      usage
      return 0
      ;;
    --version)
      printf 'pg-backup %s\n' "$SCRIPT_VERSION"
      return 0
      ;;
    --config)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        error "Для --config нужен путь к файлу"
        usage >&2
        return 2
      fi
      CONFIG_FILE="$2"
      shift 2
      continue
      ;;
    *)
      error "Неизвестный аргумент: $1"
      usage >&2
      return 2
      ;;
    esac
  done

  if [[ -n "$CONFIG_FILE" ]]; then
    load_config_file "$CONFIG_FILE" || return 2
  fi

  if open_log; then
    info "Журнал: $LOG_FILE"
  fi

  require_commands || return 2
  check_backup_dir || return 2
  check_free_space || return 2
  check_db_connection || return 2
  get_database_list || return $?
  prepare_work_dir || return 2
  setup_cleanup_trap

  # Основной цикл: сбой одной базы не останавливает остальные
  local db
  for db in "${DBS_TO_BACKUP[@]}"; do
    if backup_one_db "$db"; then
      OK_COUNT=$((OK_COUNT + 1))
    else
      FAIL_COUNT=$((FAIL_COUNT + 1))
      FAILED_DBS+=("$db")
    fi
  done

  # Сводка и код завершения: 0 — все скопированы, 1 — есть сбои
  info "Итог: всего ${#DBS_TO_BACKUP[@]}, успешно $OK_COUNT, сбой $FAIL_COUNT"
  if [[ $FAIL_COUNT -gt 0 ]]; then
    local IFS=', '
    error "Не удалось скопировать: ${FAILED_DBS[*]}"
    return 1
  fi
  info "Резервное копирование завершено успешно"
  return 0
}

# Точка входа. При импорте (PG_BACKUP_NO_MAIN=1) main не запускается —
# это позволяет unit-тестам вызывать отдельные функции скрипта.
if [[ "${PG_BACKUP_NO_MAIN:-0}" != "1" ]]; then
  main "$@"
fi
