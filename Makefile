SHELL := /usr/bin/env bash

SCRIPTS := $(wildcard scripts/*.sh)
TEST_SH := $(wildcard tests/run.sh tests/init/*.sh tests/deploy/run.sh tests/deploy/test-deploy.sh tests/deploy/init/*.sh)

.PHONY: help lint test unit deploy-test run

help:
	@echo "Available targets:"
	@echo "  help        - показать эту справку"
	@echo "  lint        - линтеры: shellcheck + shfmt"
	@echo "  test        - bats-тесты в docker-контейнере (unit + e2e)"
	@echo "  unit        - только unit-тесты (без e2e)"
	@echo "  deploy-test - deploy-тест: инструкции DEPLOYMENT.md в Ubuntu-контейнере"
	@echo "  run         - выполнить скрипт резервного копирования"

lint:
	shellcheck $(SCRIPTS) $(TEST_SH)
	shfmt -i 2 -d scripts/

test:
	bash tests/run.sh

unit:
	E2E=0 bash tests/run.sh

deploy-test:
	bash tests/deploy/run.sh

run:
	bash scripts/pg-backup.sh
