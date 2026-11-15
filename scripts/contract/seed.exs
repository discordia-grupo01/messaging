# Datos de prueba para la corrida de contrato. Se ejecuta con `mix run scripts/contract/seed.exs`
# contra las bases efimeras (el script de contrato se niega a correr si no son locales), antes de
# arrancar el servicio. Usa las mismas funciones que usa el servicio (replicas, mensajes,
# conversaciones y bloqueos), asi los documentos tienen la forma real. Los ids son fijos y los
# usa schemathesis.toml; es idempotente (client_id fijo).
alias Messaging.Chat
alias Messaging.Chat.{Blocks, ChannelCache, Conversation}
alias Messaging.Chat.Repo.Mongo, as: Repo

user = "00000000-0000-4000-8000-0000000000e1"
other = "00000000-0000-4000-8000-0000000000e2"
server = "00000000-0000-4000-8000-0000000000a1"
channel = "00000000-0000-4000-8000-0000000000b1"
role = "00000000-0000-4000-8000-0000000000c1"
now = DateTime.utc_now() |> DateTime.truncate(:millisecond)

ok! = fn
  :ok -> :ok
  {:ok, _} = result -> result
  other -> raise "seed: #{inspect(other)}"
end

# Usuarios conocidos (replica de perfiles), dueno del servidor, rol por defecto y miembros.
for id <- [user, other], do: ok!.(Repo.apply_profile(id, 1))
ok!.(Repo.apply_server_owner(server, user, now))

ok!.(
  Repo.apply_role(server, role, ["VIEW_CHANNELS", "SEND_MESSAGES", "ADD_REACTIONS"], true, now)
)

for id <- [user, other], do: ok!.(Repo.apply_member_roles(server, id, [role], now))
# El outbox de Postgres tiene un indice unico sobre los mensajes ya creados: si quedan filas de una
# corrida anterior, enviar el mismo mensaje otra vez no se aplica en Mongo. Se vacia.
Postgrex.query!(Messaging.Postgres, "TRUNCATE outbox_events", [])

# Empieza de cero el canal: un mensaje borrado en una corrida anterior no se vuelve a crear con el
# mismo client_id, y asi cada corrida arranca con los mismos mensajes vivos.
# Se borra directo en Mongo (Chat.delete_channel publicaria un evento que el servicio consumiria
# despues de sembrar y volveria a vaciar el canal).
for collection <- ["messages", "mentions", "reactions"] do
  ok!.(Mongo.delete_many(Messaging.Mongo, collection, %{"channel_id" => channel}))
end

ok!.(Chat.upsert_channel(%ChannelCache{channel_id: channel, server_id: server, name: "general", kind: "text"}))

# Mensajes con client_id fijo: el id sale de (canal, autor, client_id), asi que es siempre el mismo.
send! = fn author, client_id, content ->
  {:ok, message} =
    Chat.send_message(%{channel_id: channel, user_id: author, content: content, client_id: client_id})

  IO.puts("message #{client_id} #{message.id}")
end

send!.(user, "contract-list", "hola contrato")
send!.(user, "contract-edit", "para editar")
send!.(user, "contract-delete", "para borrar")
send!.(other, "contract-mention", "hola <@#{user}>")

# Conversacion directa con un mensaje del otro usuario (aparece en GET /v1/conversations).
{:ok, _channel, _message} =
  Chat.send_direct_message(%{
    sender_id: other,
    recipient_id: user,
    content: "mensaje directo",
    client_id: "contract-dm"
  })

IO.puts("conversation #{Conversation.id(user, other)}")

# Un bloqueo para que GET /v1/blocks y DELETE /v1/blocks/{id} tengan algo que listar o quitar.
third = "00000000-0000-4000-8000-0000000000e3"
ok!.(Repo.apply_profile(third, 1))
ok!.(Blocks.block(user, third))

# El servicio aplica en Mongo lo que encola en el outbox de forma asincronica: se espera a que no
# quede nada pendiente antes de terminar (si no, el proceso sale y la siembra queda a medias).
wait_drained = fn wait_drained, attempts ->
  %{rows: [[pending]]} =
    Postgrex.query!(
      Messaging.Postgres,
      "SELECT count(*) FROM outbox_events WHERE published_at IS NULL",
      []
    )

  cond do
    pending == 0 -> :ok
    attempts == 0 -> raise "seed: #{pending} eventos del outbox sin aplicar"
    true -> Process.sleep(200) && wait_drained.(wait_drained, attempts - 1)
  end
end

wait_drained.(wait_drained, 150)
