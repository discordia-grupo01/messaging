.PHONY: setup format lint test dialyzer ci clean

setup:
	mix local.hex --force
	mix local.rebar --force
	mix deps.get

format:
	mix format

lint:
	mix credo --strict

test:
	mix test --cover

dialyzer:
	mix dialyzer

ci: ## corre lo mismo que el pipeline de CI, en local
	@echo "--- format ---"
	mix format --check-formatted
	@echo "--- credo ---"
	mix credo --strict
	@echo "--- compile ---"
	mix compile --warnings-as-errors
	@echo "--- test ---"
	mix test --cover
	@echo "--- dialyzer ---"
	mix dialyzer
	@echo "Todo OK"

clean:
	rm -rf _build deps
	@echo "Build limpio. Corre \"make setup\" de nuevo."
