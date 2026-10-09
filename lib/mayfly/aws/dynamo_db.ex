defmodule Mayfly.AWS.DynamoDB do
  @moduledoc """
  A minimal, dependency-free DynamoDB client: `PutItem`, `GetItem`,
  `UpdateItem`, `DeleteItem` (and `request/3` for anything else) over the
  DynamoDB JSON 1.0 protocol with SigV4.

  Items are given and returned as plain Elixir maps; attribute values are
  converted with `to_attribute_values/1` and `Mayfly.Events.DynamoDB.from_attribute_values/1`.

      {:ok, _} = Mayfly.AWS.DynamoDB.put_item("orders", %{"id" => "o1", "total" => 12.5})
      {:ok, %{"id" => "o1", "total" => 12.5}} = Mayfly.AWS.DynamoDB.get_item("orders", %{"id" => "o1"})

  Conditional writes return `{:error, :conditional_check_failed}`; other API
  errors return `{:error, {type, message}}`.

  ## Configuration

  Credentials and region come from the environment (`Mayfly.AWS.Credentials`).
  `endpoint:` overrides the URL (local DynamoDB, tests); `:inets`/`:ssl` are
  started on first use.
  """

  alias Mayfly.AWS.{Credentials, HTTP}
  alias Mayfly.Events.DynamoDB, as: Events

  @type item :: %{optional(String.t()) => term()}
  @type error :: :conditional_check_failed | {String.t(), String.t()} | term()

  @doc "PutItem. Options: `condition:` expression, `names:`, `values:` (plain terms), `return: \"ALL_OLD\"`."
  @spec put_item(String.t(), item(), keyword()) :: {:ok, map()} | {:error, error()}
  def put_item(table, item, opts \\ []) do
    body =
      %{"TableName" => table, "Item" => to_attribute_values(item)}
      |> maybe("ConditionExpression", opts[:condition])
      |> maybe("ExpressionAttributeNames", opts[:names])
      |> maybe("ExpressionAttributeValues", values(opts[:values]))
      |> maybe("ReturnValues", opts[:return])

    with {:ok, resp} <- request("PutItem", body, opts), do: {:ok, decode_attributes(resp)}
  end

  @doc "GetItem by key. Returns `{:ok, item}` or `{:ok, nil}` when absent. Option `consistent: true`."
  @spec get_item(String.t(), item(), keyword()) :: {:ok, item() | nil} | {:error, error()}
  def get_item(table, key, opts \\ []) do
    body =
      %{"TableName" => table, "Key" => to_attribute_values(key)}
      |> maybe("ConsistentRead", opts[:consistent])

    with {:ok, resp} <- request("GetItem", body, opts) do
      {:ok, if(resp["Item"], do: Events.from_attribute_values(resp["Item"]), else: nil)}
    end
  end

  @doc "UpdateItem. Options: `update:` (required), `condition:`, `names:`, `values:`, `return:`."
  @spec update_item(String.t(), item(), keyword()) :: {:ok, map()} | {:error, error()}
  def update_item(table, key, opts) do
    body =
      %{
        "TableName" => table,
        "Key" => to_attribute_values(key),
        "UpdateExpression" => Keyword.fetch!(opts, :update)
      }
      |> maybe("ConditionExpression", opts[:condition])
      |> maybe("ExpressionAttributeNames", opts[:names])
      |> maybe("ExpressionAttributeValues", values(opts[:values]))
      |> maybe("ReturnValues", opts[:return])

    with {:ok, resp} <- request("UpdateItem", body, opts), do: {:ok, decode_attributes(resp)}
  end

  @doc "DeleteItem. Options: `condition:`, `names:`, `values:`, `return:`."
  @spec delete_item(String.t(), item(), keyword()) :: {:ok, map()} | {:error, error()}
  def delete_item(table, key, opts \\ []) do
    body =
      %{"TableName" => table, "Key" => to_attribute_values(key)}
      |> maybe("ConditionExpression", opts[:condition])
      |> maybe("ExpressionAttributeNames", opts[:names])
      |> maybe("ExpressionAttributeValues", values(opts[:values]))
      |> maybe("ReturnValues", opts[:return])

    with {:ok, resp} <- request("DeleteItem", body, opts), do: {:ok, decode_attributes(resp)}
  end

  @doc "Raw DynamoDB operation. `body` is the JSON request map; returns the decoded response map."
  @spec request(String.t(), map(), keyword()) :: {:ok, map()} | {:error, error()}
  def request(operation, body, opts \\ []) do
    with {:ok, creds} <- Credentials.from_env() do
      region = Keyword.get(opts, :region, creds.region)
      url = Keyword.get(opts, :endpoint) || "https://dynamodb.#{region}.amazonaws.com/"
      payload = JSON.encode!(body)

      headers =
        Mayfly.AWS.SigV4.sign(
          creds,
          "dynamodb",
          region,
          "POST",
          url,
          [
            {"content-type", "application/x-amz-json-1.0"},
            {"x-amz-target", "DynamoDB_20120810.#{operation}"}
          ],
          payload
        )

      case HTTP.post(url, headers, payload, opts) do
        {:ok, 200, resp_body} ->
          {:ok, JSON.decode!(resp_body)}

        {:ok, _status, resp_body} ->
          {:error, api_error(resp_body)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Plain terms → DynamoDB attribute values (`%{\"a\" => 1}` → `%{\"a\" => %{\"N\" => \"1\"}}`)."
  @spec to_attribute_values(map()) :: map()
  def to_attribute_values(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), to_av(v)} end)

  @doc "One term → attribute value."
  @spec to_av(term()) :: map()
  def to_av(nil), do: %{"NULL" => true}
  def to_av(b) when is_boolean(b), do: %{"BOOL" => b}
  def to_av(n) when is_integer(n), do: %{"N" => Integer.to_string(n)}
  def to_av(f) when is_float(f), do: %{"N" => Float.to_string(f)}

  def to_av(s) when is_binary(s),
    do: if(String.valid?(s), do: %{"S" => s}, else: %{"B" => Base.encode64(s)})

  def to_av(a) when is_atom(a), do: %{"S" => Atom.to_string(a)}
  def to_av(l) when is_list(l), do: %{"L" => Enum.map(l, &to_av/1)}
  def to_av(%{} = m) when not is_struct(m), do: %{"M" => to_attribute_values(m)}
  def to_av(other), do: %{"S" => inspect(other)}

  defp values(nil), do: nil
  defp values(map), do: Map.new(map, fn {k, v} -> {to_string(k), to_av(v)} end)

  defp maybe(map, _key, nil), do: map
  defp maybe(map, key, value), do: Map.put(map, key, value)

  defp decode_attributes(%{"Attributes" => attrs} = resp),
    do: Map.put(resp, "Attributes", Events.from_attribute_values(attrs))

  defp decode_attributes(resp), do: resp

  defp api_error(body) do
    case JSON.decode(body) do
      {:ok, %{"__type" => type} = err} ->
        short = type |> String.split("#") |> List.last()

        if short == "ConditionalCheckFailedException",
          do: :conditional_check_failed,
          else: {short, err["message"] || err["Message"] || ""}

      _ ->
        {"UnknownError", body}
    end
  end
end
