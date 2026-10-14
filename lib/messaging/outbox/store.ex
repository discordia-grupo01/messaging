defmodule Messaging.Outbox.Store do
  @type row :: %{
          required(:id) => String.t(),
          required(:event) => String.t(),
          required(:topic) => String.t(),
          required(:payload) => map(),
          optional(:apply) => map() | nil,
          optional(:message_id) => String.t() | nil,
          optional(:channel_id) => String.t() | nil
        }

  @type pending :: %{
          id: String.t(),
          event: String.t(),
          topic: String.t(),
          payload: map(),
          apply: map() | nil,
          message_id: String.t() | nil,
          channel_id: String.t() | nil,
          attempts: non_neg_integer()
        }

  @type outcome :: :ok | {:retry, term()} | {:error, term()}

  @callback insert([row()]) :: :ok | {:error, term()}

  @callback process_pending(limit :: pos_integer(), ([pending()] -> [{String.t(), outcome()}])) ::
              {:ok, non_neg_integer()} | {:error, term()}

  @callback ping() :: :ok | {:error, term()}

  @spec insert([row()]) :: :ok | {:error, term()}
  def insert(rows), do: impl().insert(rows)

  @spec process_pending(pos_integer(), ([pending()] -> [{String.t(), outcome()}])) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def process_pending(limit, handler), do: impl().process_pending(limit, handler)

  @spec ping() :: :ok | {:error, term()}
  def ping, do: impl().ping()

  defp impl, do: Application.get_env(:messaging, :outbox_store, Messaging.Outbox.Store.Postgres)
end
