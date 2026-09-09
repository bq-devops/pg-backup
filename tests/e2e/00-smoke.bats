#!/usr/bin/env bats
# Smoke: PostgreSQL жив и отвечает.

load '../helpers/bats-helpers'

@test "PostgreSQL отвечает на SELECT 1" {
  run psql -d postgres -tAc "SELECT 1"
  [[ "$output" == "1" ]]
}

@test "тестовые БД созданы" {
  run psql -d postgres -tAc "SELECT count(*) FROM pg_database WHERE datname IN ('orders','users','logs')"
  [[ "$output" == "3" ]]
}
