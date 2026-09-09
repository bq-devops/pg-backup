# pg-backup — развёртывание в системе

Инструкция по установке и настройке `pg-backup` на сервере **Ubuntu/Debian**.
Покрытие: зависимости, выделенный пользователь, файлы, конфигурация, каталоги.
Планировщик (cron / systemd timer) и logrotate — в разделах ниже.

> Результат: скрипт установлен в `/opt/pg-backup`, конфиг в `/etc/pg-backup.conf`,
> бэкапы в `/var/backups/pg`, журнал в `/var/log/pg-backup.log`,
> запуск от выделенного системного пользователя `pg-backup`.

## Требования

- **Ubuntu 20.04+ / Debian 11+**
- Доступ к серверу с правами `sudo`
- PostgreSQL-сервер (локальный или удалённый), доступный для дампа
- Клиентские утилиты: `pg_dump`, `psql` (пакет `postgresql-client`)
- Свободное место на диске бэкапов ≥ суммарный размер баз × 2

## Схема развёртывания

```
PostgreSQL-сервер
      │  pg_dump / psql (по PGHOST:PGPORT)
      ▼
пользователь pg-backup (системный, без логина)
      │  читает /etc/pg-backup.conf + ~/.pgpass
      │  дамп → WORK_DIR (tmp) → gzip → gzip -t → перенос
      ▼
/var/backups/pg/<база>_<ГГГГММДД-ЧЧММСС>.sql.gz
      ▲
      │  ежедневно
cron  или  systemd timer
```

## Шаг 1. Зависимости

```bash
sudo apt-get update
sudo apt-get install -y postgresql-client gzip
```

Проверка:

```bash
pg_dump --version
psql --version
gzip --version
```

## Шаг 2. Выделенный системный пользователь

Создаём системного пользователя без логина (минимальные привилегии):

```bash
sudo useradd -r -d /var/lib/pg-backup -s /usr/sbin/nologin pg-backup
sudo mkdir -p /var/lib/pg-backup
sudo chown pg-backup:pg-backup /var/lib/pg-backup
```

- `-r` — системный аккаунт (UID из системного диапазона)
- `-d /var/lib/pg-backup` — домашний каталог (тут будет `~/.pgpass`)
- `-s /usr/sbin/nologin` — интерактивный вход запрещён

## Шаг 3. Установка скрипта

Копируем скрипт и пример конфигурации в `/opt/pg-backup`:

```bash
sudo mkdir -p /opt/pg-backup
sudo cp scripts/pg-backup.sh /opt/pg-backup/pg-backup.sh
sudo cp config/pg-backup.conf.example  /opt/pg-backup/pg-backup.conf.example
sudo chown -R root:root /opt/pg-backup
sudo chmod 755 /opt/pg-backup
sudo chmod 755 /opt/pg-backup/pg-backup.sh
sudo chmod 644 /opt/pg-backup/pg-backup.conf.example
```

Проверка:

```bash
sudo -u pg-backup /opt/pg-backup/pg-backup.sh --version
# → pg-backup 0.0.1
```

## Шаг 4. Конфигурация

Создаём файл конфигурации и заполняем значения:

```bash
sudo cp config/pg-backup.conf.example /etc/pg-backup.conf
sudo vim /etc/pg-backup.conf
```

Минимальный рабочий конфиг (пароль — через `.pgpass`, см. ниже):

```ini
PGHOST=127.0.0.1
PGPORT=5432
PGUSER=backup
PGCONNECT_TIMEOUT=10
EXCLUDE_DBS=template0 template1
BACKUP_DIR=/var/backups/pg
MIN_FREE_SPACE_MB=512
LOG_FILE=/var/log/pg-backup.log
```

Права: конфиг читает пользователь `pg-backup`, пароль в нём не храним:

```bash
sudo chown root:pg-backup /etc/pg-backup.conf
sudo chmod 640 /etc/pg-backup.conf
```

### Пароль: `.pgpass` (рекомендуется)

Вместо `PGPASSWORD` в конфиге используем `~/.pgpass`
(формат: `хост:порт:база:пользователь:пароль`):

```bash
# umask 077 внутри sudo — файл создаётся сразу с правами 600 (без окна 644)
sudo bash -c 'umask 077; cat > /var/lib/pg-backup/.pgpass' <<'EOF'
127.0.0.1:5432:*:backup:secret
EOF
sudo chown pg-backup:pg-backup /var/lib/pg-backup/.pgpass
```

`psql`/`pg_dump` читают `~/.pgpass` автоматически, если `HOME=/var/lib/pg-backup`
(в cron `HOME` задаётся сам; в systemd — явно, см. раздел планировщика).

> Альтернатива: `PGPASSWORD=secret` прямо в `/etc/pg-backup.conf`
> (тогда файл должен быть `600`, владелец `pg-backup`). Менее безопасно —
> пароль лежит в общем конфиге.

## Шаг 5. Каталог бэкапов и журнал

Каталог для готовых архивов (владелец — `pg-backup`):

```bash
sudo mkdir -p /var/backups/pg
sudo chown pg-backup:pg-backup /var/backups/pg
sudo chmod 750 /var/backups/pg
```

Журнал: скрипт создаёт файл сам, но каталог `/var/log` ему не принадлежит —
выдаём права на конкретный файл заранее:

```bash
sudo touch /var/log/pg-backup.log
sudo chown pg-backup:pg-backup /var/log/pg-backup.log
sudo chmod 600 /var/log/pg-backup.log
```

## Итог развёртывания (проверка)

```bash
# Тестовый прогон от целевого пользователя
sudo -u pg-backup env HOME=/var/lib/pg-backup \
  /opt/pg-backup/pg-backup.sh --config /etc/pg-backup.conf
echo "код завершения: $?"

# Ожидаемый результат: exit 0, в /var/backups/pg — валидные архивы
ls -la /var/backups/pg/
for f in /var/backups/pg/*.sql.gz; do gzip -t "$f" && echo "OK: $f"; done
```

## Планировщик

Два варианта регулярного запуска. **Рекомендуемый — systemd timer**
(журнал в journal, статус через `systemctl`, `Persistent` не пропускает
пропущенные запуски). cron — проще, если systemd нежелателен.

### Вариант A: cron (простой)

Обёртка, которая фиксирует код завершения (скрипт сам пишет в `LOG_FILE`):

```bash
sudo tee /opt/pg-backup/run.sh > /dev/null <<'EOF'
#!/usr/bin/env bash
set -u
export HOME=/var/lib/pg-backup
/opt/pg-backup/pg-backup.sh --config /etc/pg-backup.conf
rc=$?
# при необходимости — уведомление по коду (0/1/2/3)
exit "$rc"
EOF
sudo chown root:root /opt/pg-backup/run.sh
sudo chmod 755 /opt/pg-backup/run.sh
```

Задача в `/etc/cron.d/pg-backup` (ежедневно в 02:00):

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HOME=/var/lib/pg-backup
0 2 * * * pg-backup /opt/pg-backup/run.sh >/dev/null 2>&1
```

- Вывод перенаправлен в `/dev/null`, т.к. скрипт сам пишет в `LOG_FILE`
  (`/var/log/pg-backup.log`) — единый источник журнала.
- Права на файл: `sudo chmod 644 /etc/cron.d/pg-backup`, владелец `root`.

Проверка:

```bash
sudo cat /etc/cron.d/pg-backup
sudo -u pg-backup /opt/pg-backup/run.sh; echo "код: $?"
```

### Вариант B: systemd timer (рекомендуется)

Служба `/etc/systemd/system/pg-backup.service`:

```ini
[Unit]
Description=PostgreSQL backup (pg-backup)
After=network.target

[Service]
Type=oneshot
User=pg-backup
Environment=HOME=/var/lib/pg-backup
ExecStart=/opt/pg-backup/pg-backup.sh --config /etc/pg-backup.conf
```

Таймер `/etc/systemd/system/pg-backup.timer`:

```ini
[Unit]
Description=Daily PostgreSQL backup timer

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
```

- `Persistent=true` — если машина была выключена в 02:00, запуск
  догоняется при включении.
- `RandomizedDelaySec=300` — разброс до 5 минут, чтобы не создавать
  пиковую нагрузку в одну минуту.

Активация:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now pg-backup.timer
```

Проверка и журнал:

```bash
sudo systemctl status pg-backup.timer
sudo systemctl list-timers pg-backup.timer
sudo systemctl start pg-backup.service        # ручной запуск
sudo systemctl status pg-backup.service
sudo journalctl -u pg-backup.service -n 50     # журнал запуска
```

> Скрипт пишет в `LOG_FILE`, а systemd дополнительно дублирует stderr в
> journal — оба источника доступны.

## Ротация журнала (logrotate)

Файл `/etc/logrotate.d/pg-backup`:

```
/var/log/pg-backup.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 600 pg-backup pg-backup
}
```

- `weekly` + `rotate 8` — неделя хранения, 8 архивов.
- `create 600 pg-backup pg-backup` — после ротации файл создаётся с теми же
  правами и владельцем, что и до.
- Скрипт короткоживущий (oneshot), поэтому открытые FD во время ротации —
  не проблема. Если бэкап длится долго, замените `create` на `copytruncate`.

Проверка:

```bash
sudo logrotate -d /etc/logrotate.d/pg-backup   # dry-run
```

## Итог: что установлено

| Компонент | Путь |
|-----------|------|
| Скрипт | `/opt/pg-backup/pg-backup.sh` |
| Конфиг | `/etc/pg-backup.conf` |
| Пароль | `/var/lib/pg-backup/.pgpass` |
| Бэкапы | `/var/backups/pg/` |
| Журнал | `/var/log/pg-backup.log` |
| Планировщик | `/etc/cron.d/pg-backup` **или** `pg-backup.timer` |
| Ротация | `/etc/logrotate.d/pg-backup` |

## Проверка развёртывания (чек-лист)

Быстрая проверка «всё ли работает» после установки:

| # | Проверка | Команда | Ожидаемо |
|---|----------|---------|----------|
| 1 | Скрипт на месте | `/opt/pg-backup/pg-backup.sh --version` | `pg-backup 0.0.1` |
| 2 | Конфиг читается | `sudo -u pg-backup test -r /etc/pg-backup.conf && echo OK` | `OK` |
| 3 | Тестовый прогон | `sudo -u pg-backup env HOME=/var/lib/pg-backup /opt/pg-backup/pg-backup.sh --config /etc/pg-backup.conf; echo $?` | `0` |
| 4 | Архивы валидны | `for f in /var/backups/pg/*.sql.gz; do gzip -t "$f"; done && echo OK` | `OK` |
| 5 | Планировщик активен | `systemctl is-active pg-backup.timer` **или** `cat /etc/cron.d/pg-backup` | `active` / строка cron |
| 6 | logrotate | `sudo logrotate -d /etc/logrotate.d/pg-backup` | без ошибок |

## Обновление скрипта

Совместимость: новые версии используют те же ключи конфигурации,
поэтому конфиг, каталоги и планировщик не меняются.

```bash
# 1. Сохранить старую версию (откат)
sudo cp /opt/pg-backup/pg-backup.sh /opt/pg-backup/pg-backup.sh.bak

# 2. Установить новую
sudo cp scripts/pg-backup.sh /opt/pg-backup/pg-backup.sh
sudo chown root:root /opt/pg-backup/pg-backup.sh
sudo chmod 755 /opt/pg-backup/pg-backup.sh

# 3. Проверить версию
sudo /opt/pg-backup/pg-backup.sh --version

# 4. Тестовый прогон
sudo -u pg-backup env HOME=/var/lib/pg-backup \
  /opt/pg-backup/pg-backup.sh --config /etc/pg-backup.conf
```

При сбое — откат:

```bash
sudo cp /opt/pg-backup/pg-backup.sh.bak /opt/pg-backup/pg-backup.sh
```

## Удаление

В обратном порядке установки:

```bash
# 1. Остановить планировщик
sudo systemctl disable --now pg-backup.timer   # вариант B
# или: sudo rm /etc/cron.d/pg-backup           # вариант A

# 2. Удалить файлы
sudo rm -r /opt/pg-backup
sudo rm /etc/pg-backup.conf
sudo rm -r /var/lib/pg-backup
sudo rm /etc/logrotate.d/pg-backup

# 3. Удалить пользователя
sudo userdel pg-backup
```

> **Бэкапы в `/var/backups/pg` не удаляются автоматически** —
> решение об их сохранении/удалении принимает администратор.
