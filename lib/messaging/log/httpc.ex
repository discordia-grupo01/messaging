defmodule Messaging.Log.Httpc do
  def post(url, headers, body, timeout_ms) do
    {content_type, headers} = pop_content_type(headers)

    request =
      {String.to_charlist(url), charlists(headers), String.to_charlist(content_type), body}

    case :httpc.request(:post, request, http_options(url, timeout_ms), body_format: :binary) do
      {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
        {:ok,
         %{
           status: status,
           headers: Enum.map(response_headers, fn {k, v} -> {to_string(k), to_string(v)} end),
           body: response_body
         }}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, {:failed_connect, _details}} ->
        {:error, :connect_failed}

      {:error, _reason} ->
        {:error, :request_failed}
    end
  end

  defp http_options(url, timeout_ms) do
    base = [timeout: timeout_ms, connect_timeout: timeout_ms, autoredirect: false]

    if String.starts_with?(url, "https://"),
      do: [{:ssl, tls_options(url)} | base],
      else: base
  end

  defp tls_options(url) do
    %URI{host: host} = URI.parse(url)

    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp pop_content_type(headers) do
    case Enum.split_with(headers, fn {key, _value} -> String.downcase(key) == "content-type" end) do
      {[{_key, value} | _], rest} -> {value, rest}
      {[], rest} -> {"application/octet-stream", rest}
    end
  end

  defp charlists(headers),
    do: Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
end
