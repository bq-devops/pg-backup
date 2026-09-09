# pg-backup

Bash-скрипт резервного копирования баз данных **PostgreSQL**.

Скрипт перечисляет базы, делает дамп каждой через `pg_dump`, упаковывает в
`gzip`, проверяет целостность архива (`gzip -t`) и переносит готовый архив в
каталог бэкапов. Ключевые гарантии:

- **Изоляция ошибок** — сбой одной базы не останавливает копирование остальных.
- **Только валидные архивы** — в целевой каталог попадает архив, прошедший
  проверку целостности; неполные/битые дампы отбрасываются.
- **Нулевой мусор** — временные файлы удаляются в любом сценарии завершения
  (успех, сбой, прерывание по сигналу).
- **Контроль места** — проверка свободного места на рабочем и целевом дисках
  до начала и перед переносом каждого архива.
- **Лаконичный журнал** — человекочитаемые сообщения на русском в файл и stderr.

## Требования

- **bash 4+**
- Клиентские утилиты PostgreSQL: `pg_dump`, `psql`
- `gzip`, `df`, `du`, `awk` (стандартные для Linux)
- **Docker** — только для прогона тестов (на хосте не нужны `bats` и `postgres`)

## Быстрый старт

```bash
# 1. Укажите подключение и каталог бэкапов
export PGHOST=127.0.0.1 PGPORT=5432 PGUSER=backup PGPASSWORD='secret'
export BACKUP_DIR=/var/backups/pg

# 2. Запустите
bash scripts/pg-backup.sh

# 3. Результат: /var/backups/pg/<база>_<дата-время>.sql.gz (валидные архивы)
```

Или через файл конфигурации:

```bash
cp config/pg-backup.conf.example /etc/pg-backup.conf   # заполните значения
chmod 600 /etc/pg-backup.conf               # в файле пароль
bash scripts/pg-backup.sh --config /etc/pg-backup.conf
```

## Конфигурация

Все параметры задаются переменными окружения или файлом конфигурации
(`--config`, формат `KEY=VALUE`). Пример — [`config/pg-backup.conf.example`](config/pg-backup.conf.example).

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `PGHOST` | `postgres` | Хост PostgreSQL |
| `PGPORT` | `5432` | Порт |
| `PGUSER` | — | Пользователь для дампа |
| `PGPASSWORD` | — | Пароль (лучше — `.pgpass`, см. [USAGE](docs/USAGE.md)) |
| `PGCONNECT_TIMEOUT` | `10` | Таймаут подключения, сек |
| `DB_LIST` | авто | Явный список баз через пробел; пусто = все пользовательские |
| `EXCLUDE_DBS` | `template0 template1` | Исключаемые базы |
| `BACKUP_DIR` | `/var/backups/pg` | Каталог для готовых архивов |
| `WORK_DIR` | `mktemp -d` | Рабочий каталог для дампов |
| `MIN_FREE_SPACE_MB` | `512` | Минимум свободного места, МБ (рабочий и целевой диск) |
| `LOG_FILE` | `/var/log/pg-backup.log` | Файл журнала (права 600 создаёт скрипт); пусто = только stderr |

Опции командной строки: `--config FILE`, `--help`, `--version`.

## Использование

Подробные сценарии (cron, `.pgpass`, обработка кодов завершения, troubleshooting)
— в [`docs/USAGE.md`](docs/USAGE.md).

Развёртывание на сервере (Ubuntu/Debian: установка, cron/systemd timer,
logrotate, обновление, удаление) — в [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md).

Кратко:

```bash
# Только определённые базы
DB_LIST="orders users" bash scripts/pg-backup.sh

# Отдельный диск для бэкапов, порог места 1 ГБ
BACKUP_DIR=/mnt/backup/pg MIN_FREE_SPACE_MB=1024 bash scripts/pg-backup.sh
```

## Коды завершения

| Код | Значение |
|-----|----------|
| `0` | Все базы скопированы успешно |
| `1` | Есть базы, по которым бэкап не удался (остальные скопированы) |
| `2` | Ошибка конфигурации/окружения (нет утилит, нет прав, нет места, нет подключения) |
| `3` | Не найдено ни одной базы для копирования |

## Тестирование

Тесты (bats-core) и PostgreSQL живут в docker-контейнере; на хосте нужен только Docker.

```bash
make test        # unit + e2e (62 + 6)
make unit        # только unit (без e2e)
make deploy-test # deploy-тест: инструкции DEPLOYMENT.md в Ubuntu-контейнере
make lint        # shellcheck + shfmt
```

- **unit** — отдельные функции и сценарии с заглушками (`pg_dump`, `psql`, `gzip`, `df`).
- **e2e** — реальный PostgreSQL: happy path, изоляция сбоев, восстановление, нулевой мусор.
- **deploy-test** — прогоняет инструкции `docs/DEPLOYMENT.md` в чистом Ubuntu-контейнере:
  установка, конфиг, тестовый прогон, cron, systemd timer, logrotate, обновление,
  удаление (49 проверок).

## CI

GitHub Actions (`.github/workflows/`):

- `lint.yml` — shellcheck + shfmt на каждый push/PR.
- `test.yml` — `make test` (unit + e2e в Docker) на каждый push/PR.

## Лицензия

[MIT](LICENSE).
