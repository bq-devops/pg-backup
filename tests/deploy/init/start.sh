#!/bin/bash
# Запуск PostgreSQL-кластера, создание тестовых данных, удержание контейнера.
set -e

# Старт кластера (Ubuntu: pg_ctlcluster). Версия 16 — дефолт Ubuntu 24.04.
pg_ctlcluster 16 main start

# Ожидание готовности
for _ in $(seq 1 30); do
  pg_isready -q && break
  sleep 1
done
pg_isready

# Тестовые данные
/usr/local/bin/deploy-init.sh

# Удержание контейнера
exec tail -f /dev/null
