#!/bin/bash
# Deploy-тест: шаги 1–5 из docs/DEPLOYMENT.md + тестовый прогон (итерация 8.2).
# Запускается от root в Ubuntu-контейнере; sudo доступен.
#
# Шаги последовательные, поэтому используем bash (не bats): полный отчёт
# PASS/FAIL по всем шагам, а не остановка на первом сбое.
set -u

PASS=0
FAIL=0

# check "описание" команда [аргументы...] — запускает команду, копит PASS/FAIL.
check() {
  local desc="$1"
  shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (rc=$rc)"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== Шаг 1. Зависимости ==="
# Пакеты уже в образе; apt-get идемпотентен. || true — на случай отсутствия сети.
sudo apt-get install -y postgresql-client gzip >/dev/null 2>&1 || true
check "pg_dump доступен" command -v pg_dump
check "psql доступен" command -v psql
check "gzip доступен" command -v gzip

echo "=== Шаг 2. Выделенный пользователь ==="
sudo useradd -r -d /var/lib/pg-backup -s /usr/sbin/nologin pg-backup 2>/dev/null
check "пользователь pg-backup создан" id pg-backup
check "shell = nologin" bash -c "getent passwd pg-backup | grep -q '/usr/sbin/nologin'"
check "home = /var/lib/pg-backup" bash -c "getent passwd pg-backup | grep -q ':/var/lib/pg-backup:'"
sudo mkdir -p /var/lib/pg-backup
sudo chown pg-backup:pg-backup /var/lib/pg-backup
check "home-каталог существует" test -d /var/lib/pg-backup

echo "=== Шаг 3. Установка скрипта ==="
sudo mkdir -p /opt/pg-backup
sudo cp scripts/pg-backup.sh /opt/pg-backup/pg-backup.sh
sudo cp config/pg-backup.conf.example /opt/pg-backup/pg-backup.conf.example
sudo chown -R root:root /opt/pg-backup
sudo chmod 755 /opt/pg-backup
sudo chmod 755 /opt/pg-backup/pg-backup.sh
sudo chmod 644 /opt/pg-backup/pg-backup.conf.example
check "скрипт установлен и исполняемый" test -x /opt/pg-backup/pg-backup.sh
ver=$(sudo -u pg-backup /opt/pg-backup/pg-backup.sh --version 2>/dev/null)
check "--version работает ($ver)" bash -c "echo '$ver' | grep -q '0.0.1'"

echo "=== Шаг 4. Конфигурация ==="
# Запись значений (в доках — интерактивный vim; здесь — heredoc).
# Значения тестовые: PGUSER=backup (не плейсхолдер из доков).
sudo tee /etc/pg-backup.conf >/dev/null <<'EOF'
PGHOST=127.0.0.1
PGPORT=5432
PGUSER=backup
PGCONNECT_TIMEOUT=10
EXCLUDE_DBS=template0 template1
BACKUP_DIR=/var/backups/pg
MIN_FREE_SPACE_MB=512
LOG_FILE=/var/log/pg-backup.log
EOF
sudo chown root:pg-backup /etc/pg-backup.conf
sudo chmod 640 /etc/pg-backup.conf
check "конфиг читается pg-backup" sudo -u pg-backup test -r /etc/pg-backup.conf

# .pgpass (пароль): umask 077 внутри sudo — файл сразу с правами 600
sudo bash -c 'umask 077; cat > /var/lib/pg-backup/.pgpass' <<'EOF'
127.0.0.1:5432:*:backup:backup-only
EOF
sudo chown pg-backup:pg-backup /var/lib/pg-backup/.pgpass
check ".pgpass создан" test -f /var/lib/pg-backup/.pgpass
check ".pgpass права 600" test "$(stat -c '%a' /var/lib/pg-backup/.pgpass)" = "600"
check ".pgpass владелец pg-backup" test "$(stat -c '%U' /var/lib/pg-backup/.pgpass)" = "pg-backup"

echo "=== Шаг 5. Каталог бэкапов и журнал ==="
sudo mkdir -p /var/backups/pg
sudo chown pg-backup:pg-backup /var/backups/pg
sudo chmod 750 /var/backups/pg
check "каталог бэкапов создан" test -d /var/backups/pg
check "каталог бэкапов: владелец pg-backup" test "$(stat -c '%U' /var/backups/pg)" = "pg-backup"
sudo touch /var/log/pg-backup.log
sudo chown pg-backup:pg-backup /var/log/pg-backup.log
sudo chmod 600 /var/log/pg-backup.log
check "файл журнала создан" test -f /var/log/pg-backup.log
check "журнал: владелец pg-backup" test "$(stat -c '%U' /var/log/pg-backup.log)" = "pg-backup"

echo "=== Шаг 6. Тестовый прогон ==="
sudo -u pg-backup env HOME=/var/lib/pg-backup \
  /opt/pg-backup/pg-backup.sh --config /etc/pg-backup.conf
rc=$?
check "тестовый прогон: exit 0" test "$rc" -eq 0

shopt -s nullglob
archives=(/var/backups/pg/*.sql.gz)
check "архивы созданы (${#archives[@]})" test "${#archives[@]}" -gt 0
all_valid=0
for f in "${archives[@]}"; do
  gzip -t "$f" 2>/dev/null || all_valid=1
done
check "все архивы валидны (gzip -t)" test "$all_valid" -eq 0
check "журнал не пуст" test -s /var/log/pg-backup.log

echo "=== Шаг 7. Планировщик: cron (Вариант A) ==="
# Обёртка (из доков): фиксирует код завершения, задаёт HOME
sudo tee /opt/pg-backup/run.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -u
export HOME=/var/lib/pg-backup
/opt/pg-backup/pg-backup.sh --config /etc/pg-backup.conf
rc=$?
exit "$rc"
EOF
sudo chown root:root /opt/pg-backup/run.sh
sudo chmod 755 /opt/pg-backup/run.sh
check "обёртка run.sh создана" test -x /opt/pg-backup/run.sh
check "обёртка run.sh: права 755" test "$(stat -c '%a' /opt/pg-backup/run.sh)" = "755"

# Cron-задача (из доков)
sudo tee /etc/cron.d/pg-backup >/dev/null <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
HOME=/var/lib/pg-backup
0 2 * * * pg-backup /opt/pg-backup/run.sh >/dev/null 2>&1
EOF
sudo chown root:root /etc/cron.d/pg-backup
sudo chmod 644 /etc/cron.d/pg-backup
check "cron-файл создан" test -f /etc/cron.d/pg-backup
check "cron-файл: права 644" test "$(stat -c '%a' /etc/cron.d/pg-backup)" = "644"
check "cron-файл: владелец root" test "$(stat -c '%U' /etc/cron.d/pg-backup)" = "root"
check "cron-строка на месте" bash -c "grep -q 'pg-backup /opt/pg-backup/run.sh' /etc/cron.d/pg-backup"

# Прогон обёртки (реальный бэкап, идемпотентно)
sudo -u pg-backup /opt/pg-backup/run.sh
rc=$?
check "обёртка: exit 0" test "$rc" -eq 0

echo "=== Шаг 8. Планировщик: systemd timer (Вариант B) ==="
sudo mkdir -p /etc/systemd/system
sudo tee /etc/systemd/system/pg-backup.service >/dev/null <<'EOF'
[Unit]
Description=PostgreSQL backup (pg-backup)
After=network.target

[Service]
Type=oneshot
User=pg-backup
Environment=HOME=/var/lib/pg-backup
ExecStart=/opt/pg-backup/pg-backup.sh --config /etc/pg-backup.conf
EOF
sudo tee /etc/systemd/system/pg-backup.timer >/dev/null <<'EOF'
[Unit]
Description=Daily PostgreSQL backup timer

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF
check "service-файл создан" test -f /etc/systemd/system/pg-backup.service
check "timer-файл создан" test -f /etc/systemd/system/pg-backup.timer
check "service: синтаксис (systemd-analyze)" systemd-analyze verify /etc/systemd/system/pg-backup.service
check "timer: синтаксис (systemd-analyze)" systemd-analyze verify /etc/systemd/system/pg-backup.timer

echo "=== Шаг 9. Ротация журнала (logrotate) ==="
sudo tee /etc/logrotate.d/pg-backup >/dev/null <<'EOF'
/var/log/pg-backup.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 600 pg-backup pg-backup
}
EOF
check "logrotate-конфиг создан" test -f /etc/logrotate.d/pg-backup
check "logrotate: dry-run без ошибок" sudo logrotate -d /etc/logrotate.d/pg-backup

echo "=== Шаг 10. Обновление скрипта ==="
# 1. Сохранить старую версию (откат)
sudo cp /opt/pg-backup/pg-backup.sh /opt/pg-backup/pg-backup.sh.bak
check "бэкап старой версии создан" test -f /opt/pg-backup/pg-backup.sh.bak

# 2. Установить «новую» версию (добавляем маркер — тестируем процесс обновления)
echo "# NEW VERSION (test)" | sudo tee -a /opt/pg-backup/pg-backup.sh >/dev/null
sudo chown root:root /opt/pg-backup/pg-backup.sh
sudo chmod 755 /opt/pg-backup/pg-backup.sh
check "новая версия установлена (маркер есть)" bash -c "grep -q 'NEW VERSION' /opt/pg-backup/pg-backup.sh"
check "новая версия: --version работает" sudo /opt/pg-backup/pg-backup.sh --version

# 3. Откат — восстановить старую версию
sudo cp /opt/pg-backup/pg-backup.sh.bak /opt/pg-backup/pg-backup.sh
check "откат: маркер удалён (файл восстановлен)" bash -c "! grep -q 'NEW VERSION' /opt/pg-backup/pg-backup.sh"
check "откат: --version работает" sudo /opt/pg-backup/pg-backup.sh --version

# 4. Тестовый прогон после отката (старая версия работает)
sudo -u pg-backup env HOME=/var/lib/pg-backup \
  /opt/pg-backup/pg-backup.sh --config /etc/pg-backup.conf
rc=$?
check "после отката: тестовый прогон exit 0" test "$rc" -eq 0

echo "=== Шаг 11. Удаление ==="
# Бэкапы должны сохраниться (решение об удалении — за администратором)
shopt -s nullglob
backups_before=(/var/backups/pg/*.sql.gz)
check "бэкапы существуют до удаления (${#backups_before[@]})" test "${#backups_before[@]}" -gt 0

# 1. Остановить планировщик (Вариант A: cron)
sudo rm /etc/cron.d/pg-backup
check "cron-файл удалён" test ! -f /etc/cron.d/pg-backup

# 2. Удалить файлы
sudo rm -r /opt/pg-backup
sudo rm /etc/pg-backup.conf
sudo rm -r /var/lib/pg-backup
sudo rm /etc/logrotate.d/pg-backup
check "каталог скрипта удалён" test ! -d /opt/pg-backup
check "конфиг удалён" test ! -f /etc/pg-backup.conf
check "home-каталог удалён" test ! -d /var/lib/pg-backup
check "logrotate-конфиг удалён" test ! -f /etc/logrotate.d/pg-backup

# 3. Удалить пользователя
sudo userdel pg-backup
check "пользователь удалён" bash -c "! id pg-backup"

# 4. Бэкапы НЕ удалены
shopt -s nullglob
backups_after=(/var/backups/pg/*.sql.gz)
check "бэкапы сохранены после удаления (${#backups_after[@]})" test "${#backups_after[@]}" -gt 0
check "бэкапы: количество не изменилось" test "${#backups_after[@]}" -eq "${#backups_before[@]}"

echo ""
echo "=== Итог: $PASS passed, $FAIL failed ==="
test "$FAIL" -eq 0
