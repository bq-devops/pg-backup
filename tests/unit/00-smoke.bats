#!/usr/bin/env bats
# Smoke: скрипт на месте и синтаксически корректен.

load '../helpers/bats-helpers'

@test "скрипт существует" {
  [[ -f "$SCRIPT" ]]
}

@test "синтаксис bash корректен" {
  bash -n "$SCRIPT"
}
