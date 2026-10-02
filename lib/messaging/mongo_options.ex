defmodule Messaging.MongoOptions do
  @spec build(String.t()) :: keyword()
  def build(url) do
    [name: Messaging.Mongo, url: url] ++ ssl(url)
  end

  defp ssl(url) do
    if tls?(url) do
      [
        ssl_opts: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
      ]
    else
      []
    end
  end

  defp tls?(url), do: String.starts_with?(url, "mongodb+srv://") or url =~ ~r/[?&](tls|ssl)=true/
end
