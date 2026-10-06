defmodule Messaging.Chat.Mentions do

  @user_token ~r/<@([A-Za-z0-9_-]{1,64})>/
  @role_token ~r/<@&([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})>/
  @everyone_token ~r/(?<![\w@&<])@everyone(?![\w-])/

  @max_user_ids 50
  @max_role_ids 20

  @type query :: %{user_ids: [String.t()], role_ids: [String.t()], everyone: boolean()}

  @enforce_keys [:user_ids, :role_ids, :everyone, :recipient_ids]
  defstruct [:user_ids, :role_ids, :everyone, :recipient_ids]

  @type t :: %__MODULE__{
          user_ids: [String.t()],
          role_ids: [String.t()],
          everyone: boolean(),
          recipient_ids: [String.t()]
        }

  @spec parse(String.t()) :: query()
  def parse(content) when is_binary(content) do
    %{
      user_ids: content |> scan(@user_token) |> Enum.uniq() |> Enum.take(@max_user_ids),
      role_ids:
        content
        |> scan(@role_token)
        |> Enum.map(&String.downcase/1)
        |> Enum.uniq()
        |> Enum.take(@max_role_ids),
      everyone: Regex.match?(@everyone_token, content)
    }
  end

  @spec any?(query()) :: boolean()
  def any?(%{user_ids: [], role_ids: [], everyone: false}), do: false
  def any?(%{}), do: true

  @spec none() :: t()
  def none, do: %__MODULE__{user_ids: [], role_ids: [], everyone: false, recipient_ids: []}

  @spec message_fields(t()) :: map()
  def message_fields(%__MODULE__{} = resolution) do
    %{
      "mentions" => resolution.user_ids,
      "mention_roles" => resolution.role_ids,
      "mention_everyone" => resolution.everyone
    }
  end

  defp scan(content, regex) do
    regex
    |> Regex.scan(content, capture: :all_but_first)
    |> List.flatten()
  end
end
