#!/bin/sh
# Тестовые данные для e2e-прогонов.
# Исполняется entrypoint'ом postgres при первой инициализации контейнера.
# Сбой здесь = сбой инициализации контейнера (set -e + ON_ERROR_STOP).
#
# Важно: суперпользователь — POSTGRES_USER (tester), а не postgres,
# поэтому все psql-вызовы явно указывают -U.
set -e

SU="${POSTGRES_USER:-tester}"

# Пользователи:
#  - tester      — суперпользователь (создан entrypoint'ом из POSTGRES_USER)
#  - backup — обычный пользователь, у которого есть права только на orders/users/logs
#  - owner_x     — владелец «закрытой» БД restricted, до которой у backup нет доступа
psql -U "$SU" -v ON_ERROR_STOP=1 <<'SQL'
CREATE USER owner_x PASSWORD 'x-only';
CREATE USER backup PASSWORD 'backup-only';
CREATE DATABASE orders;
CREATE DATABASE users;
CREATE DATABASE logs;
CREATE DATABASE restricted OWNER owner_x;
GRANT CONNECT ON DATABASE orders TO backup;
GRANT CONNECT ON DATABASE users TO backup;
GRANT CONNECT ON DATABASE logs TO backup;
SQL

# orders: 5 строк
psql -U "$SU" -v ON_ERROR_STOP=1 -d orders <<'SQL'
CREATE TABLE orders (id serial PRIMARY KEY, customer text NOT NULL, total numeric(10,2) NOT NULL);
INSERT INTO orders (customer, total) VALUES
  ('Алиса', 1500.00), ('Борис', 2300.50), ('Вера', 890.00),
  ('Глеб', 4100.75), ('Дарья', 320.00);
GRANT USAGE ON SCHEMA public TO backup;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO backup;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO backup;
SQL

# users: 5 строк
psql -U "$SU" -v ON_ERROR_STOP=1 -d users <<'SQL'
CREATE TABLE users (id serial PRIMARY KEY, email text UNIQUE NOT NULL, name text NOT NULL);
INSERT INTO users (email, name) VALUES
  ('a@example.com', 'Алиса'), ('b@example.com', 'Борис'), ('v@example.com', 'Вера'),
  ('g@example.com', 'Глеб'), ('d@example.com', 'Дарья');
GRANT USAGE ON SCHEMA public TO backup;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO backup;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO backup;
SQL

# logs: 10 строк
psql -U "$SU" -v ON_ERROR_STOP=1 -d logs <<'SQL'
CREATE TABLE logs (id bigserial PRIMARY KEY, ts timestamptz NOT NULL DEFAULT now(), msg text NOT NULL);
INSERT INTO logs (msg) SELECT 'событие ' || g FROM generate_series(1, 10) g;
GRANT USAGE ON SCHEMA public TO backup;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO backup;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO backup;
SQL

# restricted: таблица принадлежит owner_x, у backup нет ни одного права
psql -U owner_x -v ON_ERROR_STOP=1 -d restricted <<'SQL'
CREATE TABLE secrets (id serial PRIMARY KEY, data text NOT NULL);
INSERT INTO secrets (data) VALUES ('секрет 1'), ('секрет 2');
REVOKE ALL ON TABLE secrets FROM PUBLIC;
SQL
