.PHONY: setup format lint test dialyzer openapi migrate ci clean

-include .env
export

DATABASE_HOST ?= localhost
DATABASE_PORT ?= 5432
DATABASE_NAME ?= postgres
DATABASE_USER ?= postgres
DATABASE_PASSWORD ?= postgres
DATABASE_SSLMODE ?= disable

setup:
	mix local.hex --force
	mix local.rebar --force
	mix deps.get

format:
	mix format

lint:
	mix credo --strict

test:
	MIX_ENV=test mix coveralls

dialyzer:
	mix dialyzer

openapi:
	mix openapi.spec.yaml --spec MessagingWeb.ApiSpec openapi.yaml

migrate: ## aplica migrations/*.up.sql en la base que indique .env (solo corre las nuevas)
	docker run --rm -v $(shell pwd)/migrations:/migrations --net=host migrate/migrate \
		-path=/migrations \
		-database "postgres://$(DATABASE_USER):$(DATABASE_PASSWORD)@$(DATABASE_HOST):$(DATABASE_PORT)/$(DATABASE_NAME)?sslmode=$(DATABASE_SSLMODE)$(if $(DATABASE_SCHEMA),&search_path=$(DATABASE_SCHEMA),)" \
		up

ci: ## corre lo mismo que el pipeline de CI, en local
	@echo "--- format ---"
	mix format --check-formatted
	@echo "--- credo ---"
	mix credo --strict
	@echo "--- compile ---"
	mix compile --warnings-as-errors
	@echo "--- sobelow ---"
	mix sobelow --config
	@echo "--- test ---"
	MIX_ENV=test mix coveralls
	@echo "--- dialyzer ---"
	mix dialyzer
	@echo "Todo OK"

clean:
	rm -rf _build deps
	@echo "Build limpio. Corre \"make setup\" de nuevo."
