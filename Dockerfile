FROM hexpm/elixir:1.16.2-erlang-26.2.1-alpine-3.19.1 AS builder
WORKDIR /app
RUN apk add --no-cache git && mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock* ./
RUN mix deps.get --only prod
COPY . .
ENV MIX_ENV=prod
RUN mix compile && mix release

FROM alpine:3.19.1
RUN apk add --no-cache libstdc++ openssl ncurses-libs ca-certificates
WORKDIR /app
COPY --from=builder /app/_build/prod/rel/messaging ./
EXPOSE 4000
CMD ["bin/messaging", "start"]
