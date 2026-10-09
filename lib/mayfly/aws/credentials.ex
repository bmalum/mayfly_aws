defmodule Mayfly.AWS.Credentials do
  @moduledoc """
  AWS credentials from the environment. Lambda always provides
  `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` and
  `AWS_REGION` for the execution role, so no IMDS or profile lookup is needed
  (or wanted: it would cost cold-start time).

  Outside Lambda (tests, `mix lambda.invoke`) the same variables are read, so
  `aws configure export-credentials --format env` or an SSO session exported
  to the environment works.
  """

  @type t :: %__MODULE__{
          access_key_id: String.t(),
          secret_access_key: String.t(),
          session_token: String.t() | nil,
          region: String.t()
        }

  defstruct [:access_key_id, :secret_access_key, :session_token, :region]

  @doc "Reads credentials from the environment."
  @spec from_env() :: {:ok, t()} | {:error, :missing_credentials}
  def from_env do
    with key when is_binary(key) <- System.get_env("AWS_ACCESS_KEY_ID"),
         secret when is_binary(secret) <- System.get_env("AWS_SECRET_ACCESS_KEY") do
      {:ok,
       %__MODULE__{
         access_key_id: key,
         secret_access_key: secret,
         session_token: System.get_env("AWS_SESSION_TOKEN"),
         region:
           System.get_env("AWS_REGION") || System.get_env("AWS_DEFAULT_REGION") || "us-east-1"
       }}
    else
      _ -> {:error, :missing_credentials}
    end
  end

  @doc "Like `from_env/0` but raises."
  @spec from_env!() :: t()
  def from_env! do
    case from_env() do
      {:ok, creds} ->
        creds

      {:error, :missing_credentials} ->
        raise "AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY are not set"
    end
  end
end
