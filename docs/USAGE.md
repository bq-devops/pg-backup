# pg-backup — подробное использование

Практические сценарии: запуск, cron, безопасное хранение пароля,
обработка кодов завершения, частые проблемы.

## 1. Базовый запуск через переменные окружения

```bash
export PGHOST=127.0.0.1
export PGPORT=5432
export PGUSER=backup
export PGPASSWORD='secret'
export BACKUP_DIR=/var/backups/pg

bash scripts/pg-backup.sh
```

Скрипт скопирует все пользовательские базы (кроме `template0`/`template1`)
в `/var/backups/pg/<база>_<ГГГГММДД-ЧЧММСС>.sql.gz`.

## 2. Запуск через файл конфигурации

```bash
cp config/pg-backup.conf.example /etc/pg-backup.conf
# отредактируйте /etc/pg-backup.conf (KEY=VALUE, по одному на строку)
chmod 600 /etc/pg-backup.conf        # в файле пароль — ограничьте доступ

bash scripts/pg-backup.sh --config /etc/pg-backup.conf
```

Файл конфигурации читается строгим парсером `KEY=VALUE` (без `source`),
поэтому произвольный код из файла выполнению не подвергается.

## 3. Ежедневный бэкап через cron

Пример: каждый день в 02:00, лог в файл, уведомление при сбое.

```cron
0 2 * * * /usr/bin/env PGHOST=127.0.0.1 PGUSER=backup PGPASSWORD='secret' BACKUP_DIR=/var/backups/pg /opt/pg-backup/scripts/pg-backup.sh >> /var/log/pg-backup-cron.log 2>&1
```

Более аккуратно — обёртка, которая реагирует на код завершения:

```bash
#!/usr/bin/env bash
# /opt/pg-backup/run-daily.sh
set -u
export PGHOST=127.0.0.1 PGUSER=backup PGPASSWORD='secret' BACKUP_DIR=/var/backups/pg
bash /opt/pg-backup/scripts/pg-backup.sh
rc=$?
case "$rc" in
  0) : ;;                                   # всё скопировано
  1) echo "pg-backup: есть сбои по базам" >&2 ;;
  2) echo "pg-backup: ошибка окружения" >&2 ;;
  3) echo "pg-backup: не найдено баз" >&2 ;;
esac
exit "$rc"
```

```cron
0 2 * * * /opt/pg-backup/run-daily.sh >> /var/log/pg-backup-cron.log 2>&1
```

## 4. Безопасное хранение пароля (.pgpass)

Вместо `PGPASSWORD` в окружении/конфиге используйте `.pgpass`
(формат: `хост:порт:база:пользователь:пароль`):

```bash
umask 077
cat >> ~/.pgpass <<'EOF'
127.0.0.1:5432:*:backup:secret
EOF
chmod 600 ~/.pgpass
```

Тогда `PGPASSWORD` не нужен ни в окружении, ни в конфиге — пароль не
попадает ни в `ps aux`, ни в файл конфигурации.

## 5. Коды завершения

| Код | Значение | Что делать |
|-----|----------|------------|
| `0` | Все базы скопированы | — |
| `1` | Есть базы с сбоем (остальные скопированы) | Проверить журнал, повторить упавшие |
| `2` | Ошибка окружения (утилиты/права/место/подключение) | Исправить окружение |
| `3` | Не найдено баз для копирования | Проверить `DB_LIST`/`EXCLUDE_DBS`/права |

В cron/обёртке ветвление по коду — как в примере раздела 3.

## 6. Частые проблемы

**«Не удалось подключиться к серверу»**
- Проверьте `PGHOST`/`PGPORT`/`PGUSER`, доступность сервера.
- Увеличьте `PGCONNECT_TIMEOUT`, если сеть медленная.

**«На целевом диске мало места»**
- Освободите место в `BACKUP_DIR` или снизьте `MIN_FREE_SPACE_MB`
  (не ниже реального размера баз).

**«Архив с таким именем уже существует»**
- Коллизия имён при нескольких запусках в одну секунду.
- Запускайте бэкапы последовательно (cron с интервалом).

**«База X: дамп не удался: permission denied»**
- У пользователя нет `SELECT` на таблицы базы.
- Выдайте права или исключите базу через `EXCLUDE_DBS`.

**Журнал пуст, а сообщения есть только в stderr**
- Скрипт не смог открыть `LOG_FILE` (нет прав на каталог).
- Проверьте права на каталог журнала или задайте `LOG_FILE` в доступном месте.
