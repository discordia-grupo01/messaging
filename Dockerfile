FROM elixir:1.16-alpine AS builder
WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock* ./
RUN mix deps.get --only prod
COPY . .
ENV MIX_ENV=prod
RUN mix compile && mix release

FROM alpine:3.19
RUN apk add --no-cache libstdc++ openssl ncurses-libs
WORKDIR /app
COPY --from=builder /app/_build/prod/rel/my_app ./
EXPOSE 4000
CMD ["bin/my_app", "start"]
