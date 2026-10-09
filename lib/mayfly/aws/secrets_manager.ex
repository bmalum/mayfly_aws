defmodule Mayfly.AWS.SecretsManager do
  @moduledoc """
  Secrets Manager reads.

      {:ok, %{"username" => u, "password" => p}} = SecretsManager.get_secret_json("prod/db")
      {:ok, api_key} = SecretsManager.get_secret_value("prod/api-key")

  Fetch in `init/1`, not per invocation: each call is an HTTPS round trip and
  Secrets Manager bills per 10 000 API calls.
  """

  alias Mayfly.AWS.{JSONProtocol, Request}

  @target "secretsmanager"
  @ct "application/x-amz-json-1.1"

  @doc "GetSecretValue: the `SecretString` (or Base64-decoded `SecretBinary`). Options: `version_id:`, `version_stage:`."
  @spec get_secret_value(String.t(), keyword()) :: {:ok, binary()} | {:error, Request.error()}
  def get_secret_value(secret_id, opts \\ []) do
    params =
      %{"SecretId" => secret_id}
      |> then(&if(opts[:version_id], do: Map.put(&1, "VersionId", opts[:version_id]), else: &1))
      |> then(
        &if(opts[:version_stage], do: Map.put(&1, "VersionStage", opts[:version_stage]), else: &1)
      )

    with {:ok, resp} <- call("GetSecretValue", params, opts) do
      case resp do
        %{"SecretString" => s} ->
          {:ok, s}

        %{"SecretBinary" => b} ->
          {:ok, Base.decode64!(b)}

        _ ->
          {:error,
           {"EmptySecret", "secret #{secret_id} has neither SecretString nor SecretBinary"}}
      end
    end
  end

  @doc "`get_secret_value/2` plus `JSON.decode!/1` (the common key/value secret)."
  @spec get_secret_json(String.t(), keyword()) :: {:ok, term()} | {:error, Request.error()}
  def get_secret_json(secret_id, opts \\ []) do
    with {:ok, s} <- get_secret_value(secret_id, opts) do
      case JSON.decode(s) do
        {:ok, term} -> {:ok, term}
        {:error, _} -> {:error, {"InvalidJSON", "secret #{secret_id} is not JSON"}}
      end
    end
  end

  @doc "Raw Secrets Manager operation."
  @spec call(String.t(), map(), keyword()) :: {:ok, map()} | {:error, Request.error()}
  def call(operation, params, opts \\ []),
    do: JSONProtocol.call("secretsmanager", @target, operation, params, @ct, opts)
end
