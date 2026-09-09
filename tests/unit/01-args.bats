#!/usr/bin/env bats
# Тесты аргументов командной строки.
# Все сценарии — ранний выход main() до preflight, поэтому shim'ы не нужны.

load '../helpers/bats-helpers'

@test "--help: exit 0 и текст справки" {
  run run_script --help
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"Использование"* ]]
}

@test "-h: exit 0" {
  run run_script -h
  [[ "$status" -eq 0 ]]
}

@test "--version: exit 0 и версия" {
  run run_script --version
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"pg-backup 0.0.1"* ]]
}

@test "неизвестный аргумент: exit 2 и понятная ошибка" {
  run run_script --bogus
  [[ "$status" -eq 2 ]]
  [[ "$output" == *"Неизвестный аргумент"* ]]
}

@test "--config без значения: exit 2" {
  run run_script --config
  [[ "$status" -eq 2 ]]
  [[ "$output" == *"Для --config нужен путь"* ]]
}

@test "--config с пустым значением: exit 2" {
  run run_script --config ""
  [[ "$status" -eq 2 ]]
}
