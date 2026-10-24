defmodule MessagingWeb.MessagePayload do
  @max_client_id_length 64

  @spec content(map()) :: {:ok, String.t()} | :error
  def content(%{"content" => content}) when is_binary(content), do: {:ok, content}
  def content(%{"content" => _other}), do: :error
  def content(%{"attachment_ids" => ids}) when is_list(ids), do: {:ok, ""}
  def content(_payload), do: :error

  @spec client_id(map()) :: {:ok, String.t() | nil} | :error
  def client_id(%{"client_id" => id})
      when is_binary(id) and byte_size(id) in 1..@max_client_id_length,
      do: {:ok, id}

  def client_id(%{"client_id" => nil}), do: {:ok, nil}
  def client_id(%{"client_id" => _other}), do: :error
  def client_id(_payload), do: {:ok, nil}
end
