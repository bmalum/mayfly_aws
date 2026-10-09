defmodule Mayfly.AWS.SSM do
  @moduledoc """
  SSM Parameter Store reads. Fetch configuration once in `init/1` and keep it
  in the handler state; SecureString values are decrypted (`with_decryption`
  defaults to true).

      def init(_), do: {:ok, %{config: SSM.get_parameters_by_path!("/myapp/prod/")}}

  """

  alias Mayfly.AWS.{JSONProtocol, Request}

  @target "AmazonSSM"
  @ct "application/x-amz-json-1.1"

  @type parameter :: %{name: String.t(), value: String.t(), type: String.t(), version: integer()}

  @doc "GetParameter. Returns `{:ok, value}`; `{:error, {\"ParameterNotFound\", _}}` when missing."
  @spec get_parameter(String.t(), keyword()) :: {:ok, String.t()} | {:error, Request.error()}
  def get_parameter(name, opts \\ []) do
    params = %{"Name" => name, "WithDecryption" => Keyword.get(opts, :with_decryption, true)}

    with {:ok, %{"Parameter" => p}} <- call("GetParameter", params, opts), do: {:ok, p["Value"]}
  end

  @doc "GetParameters (up to 10 names). Returns `{:ok, %{name => value}, invalid_names}`."
  @spec get_parameters([String.t()], keyword()) ::
          {:ok, %{String.t() => String.t()}, [String.t()]} | {:error, Request.error()}
  def get_parameters(names, opts \\ []) do
    params = %{"Names" => names, "WithDecryption" => Keyword.get(opts, :with_decryption, true)}

    with {:ok, resp} <- call("GetParameters", params, opts) do
      {:ok, Map.new(resp["Parameters"] || [], &{&1["Name"], &1["Value"]}),
       resp["InvalidParameters"] || []}
    end
  end

  @doc """
  GetParametersByPath, following `NextToken` until all pages are read.
  Returns `{:ok, %{name => value}}` with full names as keys (`strip_prefix: true`
  turns `/myapp/prod/db_url` into `"db_url"`). Options: `recursive:` (default true).
  """
  @spec get_parameters_by_path(String.t(), keyword()) ::
          {:ok, %{String.t() => String.t()}} | {:error, Request.error()}
  def get_parameters_by_path(path, opts \\ []), do: by_path(path, opts, nil, %{})

  @doc "Like `get_parameters_by_path/2` but raises on error."
  @spec get_parameters_by_path!(String.t(), keyword()) :: %{String.t() => String.t()}
  def get_parameters_by_path!(path, opts \\ []) do
    case get_parameters_by_path(path, opts) do
      {:ok, map} -> map
      {:error, reason} -> raise "SSM GetParametersByPath #{path} failed: #{inspect(reason)}"
    end
  end

  defp by_path(path, opts, token, acc) do
    params =
      %{
        "Path" => path,
        "Recursive" => Keyword.get(opts, :recursive, true),
        "WithDecryption" => Keyword.get(opts, :with_decryption, true),
        "MaxResults" => 10
      }
      |> then(&if(token, do: Map.put(&1, "NextToken", token), else: &1))

    with {:ok, resp} <- call("GetParametersByPath", params, opts) do
      acc =
        Enum.reduce(resp["Parameters"] || [], acc, fn p, m ->
          name =
            if Keyword.get(opts, :strip_prefix, false),
              do: String.replace_prefix(p["Name"], path, ""),
              else: p["Name"]

          Map.put(m, name, p["Value"])
        end)

      case resp["NextToken"] do
        nil -> {:ok, acc}
        next -> by_path(path, opts, next, acc)
      end
    end
  end

  @doc "Raw SSM operation."
  @spec call(String.t(), map(), keyword()) :: {:ok, map()} | {:error, Request.error()}
  def call(operation, params, opts \\ []),
    do: JSONProtocol.call("ssm", @target, operation, params, @ct, opts)
end
