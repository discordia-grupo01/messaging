defmodule MessagingWeb.MessagePayload do
  @spec content(map()) :: {:ok, String.t()} | :error
  def content(%{"content" => content}) when is_binary(content), do: {:ok, content}
  def content(%{"content" => _other}), do: :error
  def content(%{"attachment_ids" => ids}) when is_list(ids), do: {:ok, ""}
  def content(_payload), do: :error
end
