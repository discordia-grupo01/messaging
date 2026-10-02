.PHONY: setup format lint test dialyzer openapi ci clean

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

ci: ## corre lo mismo que el pipeline de CI, en local
	@echo "--- format ---"
	mix format --check-formatted
	@echo "--- credo ---"
	mix credo --strict
	@echo "--- compile ---"
	mix compile --warnings-as-errors
	@echo "--- test ---"
	MIX_ENV=test mix coveralls
	@echo "--- dialyzer ---"
	mix dialyzer
	@echo "Todo OK"

clean:
	rm -rf _build deps
	@echo "Build limpio. Corre \"make setup\" de nuevo."
