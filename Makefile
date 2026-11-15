.PHONY: setup format lint test dialyzer openapi migrate ci clean contract-deps-up contract-deps-down contract-test

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

# Prueba de contrato (Schemathesis contra el servicio real). Contenedores propios contract-messaging-*,
# puertos de host 55506 (Postgres), 55516 (RabbitMQ) y 55526 (Mongo); el servicio corre en 18086.
CONTRACT_PG_PORT ?= 55506
CONTRACT_RABBITMQ_PORT ?= 55516
CONTRACT_MONGO_PORT ?= 55526

contract-deps-up:
	@docker rm -f contract-messaging-pg contract-messaging-mongo contract-messaging-rabbitmq >/dev/null 2>&1 || true
	docker run -d --name contract-messaging-pg -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=messaging_contract -p 127.0.0.1:$(CONTRACT_PG_PORT):5432 postgres:16-alpine >/dev/null
	docker run -d --name contract-messaging-mongo -p 127.0.0.1:$(CONTRACT_MONGO_PORT):27017 mongo:7 >/dev/null
	docker run -d --name contract-messaging-rabbitmq -p 127.0.0.1:$(CONTRACT_RABBITMQ_PORT):5672 rabbitmq:3.13-management-alpine >/dev/null
	@until docker exec contract-messaging-pg pg_isready -U postgres >/dev/null 2>&1; do sleep 2; done
	@until docker exec contract-messaging-mongo mongosh --quiet --eval 'db.runCommand({ping: 1})' >/dev/null 2>&1; do sleep 2; done
	@until docker exec contract-messaging-rabbitmq rabbitmq-diagnostics -q ping >/dev/null 2>&1; do sleep 2; done
	@echo "Postgres en $(CONTRACT_PG_PORT), RabbitMQ en $(CONTRACT_RABBITMQ_PORT) y Mongo en $(CONTRACT_MONGO_PORT) listos"

contract-deps-down:
	@docker rm -f contract-messaging-app contract-messaging-pg contract-messaging-mongo contract-messaging-rabbitmq >/dev/null 2>&1 || true
	@echo "Contenedores de contrato apagados"

contract-test:
	APP_PORT=18086 DATABASE_HOST=localhost DATABASE_PORT=$(CONTRACT_PG_PORT) DATABASE_NAME=messaging_contract 	MONGO_URL=mongodb://localhost:$(CONTRACT_MONGO_PORT)/messaging_contract 	RABBITMQ_URL=amqp://guest:guest@localhost:$(CONTRACT_RABBITMQ_PORT) 	./scripts/contract-test.sh

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
