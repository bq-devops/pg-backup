#!/bin/bash
# Тестовые данные для deploy-теста.
# Суперпользователь — postgres (дефолт Ubuntu); peer-auth требует запуска
# через sudo -u postgres.
#
# Окружение «чистое»: все БД доступны backup (deploy-тест проверяет
# инструкции DEPLOYMENT.md, а не изоляцию сбоев — то покрывают e2e-тесты).
set -e

sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres <<'SQL'
CREATE USER backup PASSWORD 'backup-only';
CREATE DATABASE orders;
CREATE DATABASE users;
CREATE DATABASE logs;
GRANT CONNECT ON DATABASE orders TO backup;
GRANT CONNECT ON DATABASE users TO backup;
GRANT CONNECT ON DATABASE logs TO backup;
SQL

sudo -u postgres psql -v ON_ERROR_STOP=1 -d orders <<'SQL'
CREATE TABLE orders (id serial PRIMARY KEY, customer text NOT NULL, total numeric(10,2) NOT NULL);
INSERT INTO orders (customer, total) VALUES
  ('Алиса', 1500.00), ('Борис', 2300.50), ('Вера', 890.00),
  ('Глеб', 4100.75), ('Дарья', 320.00);
GRANT USAGE ON SCHEMA public TO backup;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO backup;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO backup;
SQL

sudo -u postgres psql -v ON_ERROR_STOP=1 -d users <<'SQL'
CREATE TABLE users (id serial PRIMARY KEY, email text UNIQUE NOT NULL, name text NOT NULL);
INSERT INTO users (email, name) VALUES
  ('a@example.com', 'Алиса'), ('b@example.com', 'Борис'), ('v@example.com', 'Вера'),
  ('g@example.com', 'Глеб'), ('d@example.com', 'Дарья');
GRANT USAGE ON SCHEMA public TO backup;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO backup;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO backup;
SQL

sudo -u postgres psql -v ON_ERROR_STOP=1 -d logs <<'SQL'
CREATE TABLE logs (id bigserial PRIMARY KEY, ts timestamptz NOT NULL DEFAULT now(), msg text NOT NULL);
INSERT INTO logs (msg) SELECT 'событие ' || g FROM generate_series(1, 10) g;
GRANT USAGE ON SCHEMA public TO backup;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO backup;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO backup;
SQL
