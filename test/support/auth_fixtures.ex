defmodule Messaging.AuthFixtures do
  alias Messaging.Auth.Token

  def token_for(user_id, opts \\ []) do
    secret = Application.fetch_env!(:messaging, :jwt_secret)
    signer = Joken.Signer.create("HS256", secret)
    exp = System.system_time(:second) + Keyword.get(opts, :ttl, 3_600)

    {:ok, token, _claims} = Token.generate_and_sign(%{"sub" => user_id, "exp" => exp}, signer)

    token
  end
end
