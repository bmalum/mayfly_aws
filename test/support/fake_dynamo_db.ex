defmodule Mayfly.AWS.FakeDynamoDB do
  @moduledoc """
  In-memory DynamoDB over plain HTTP for tests. Implements PutItem (with the
  condition expressions Mayfly.Idempotency uses), GetItem, UpdateItem (SET
  only) and DeleteItem. Not a general DynamoDB emulator.
  """
  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)
  def endpoint(pid), do: "http://127.0.0.1:#{GenServer.call(pid, :port)}/"
  def items(pid), do: GenServer.call(pid, :items)
  def put_raw(pid, item), do: GenServer.call(pid, {:put_raw, item})

  @impl true
  def init(_opts) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, packet: :http_bin, active: false, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    server = self()
    spawn_link(fn -> accept(listen, server) end)
    {:ok, %{port: port, items: %{}}}
  end

  @impl true
  def handle_call(:port, _f, s), do: {:reply, s.port, s}
  def handle_call(:items, _f, s), do: {:reply, s.items, s}

  def handle_call({:put_raw, item}, _f, s),
    do: {:reply, :ok, %{s | items: Map.put(s.items, item["id"]["S"], item)}}

  def handle_call({:op, op, body}, _f, s) do
    {status, resp, items} =
      try do
        handle_op(op, body, s.items)
      catch
        {:conditional, items} -> {400, conditional_failed(), items}
      end

    {:reply, {status, resp}, %{s | items: items}}
  end

  defp conditional_failed,
    do: %{
      "__type" => "com.amazonaws.dynamodb.v20120810#ConditionalCheckFailedException",
      "message" => "The conditional request failed"
    }

  # Supports the single equality condition the idempotency module uses on
  # Update/Delete: "#t = :token" (names/values resolved).
  defp equality_ok?(%{"ConditionExpression" => cond} = b, existing) when is_binary(cond) do
    names = b["ExpressionAttributeNames"] || %{}
    values = b["ExpressionAttributeValues"] || %{}

    case Regex.run(~r/^\s*(#?\w+)\s*=\s*(:\w+)\s*$/, cond) do
      [_, attr, val] ->
        attr = Map.get(names, attr, attr)
        existing != nil and existing[attr] == values[val]

      nil ->
        true
    end
  end

  defp equality_ok?(_b, _existing), do: true

  # -- operations (items stored as attribute-value maps) ---------------------------

  defp handle_op("PutItem", %{"TableName" => _, "Item" => item} = b, items) do
    key = item["id"]["S"]
    existing = items[key]

    if condition_ok?(
         b["ConditionExpression"],
         existing,
         b["ExpressionAttributeValues"],
         b["ExpressionAttributeNames"]
       ) do
      {200, %{}, Map.put(items, key, item)}
    else
      {400,
       %{
         "__type" => "com.amazonaws.dynamodb.v20120810#ConditionalCheckFailedException",
         "message" => "The conditional request failed"
       }, items}
    end
  end

  defp handle_op("GetItem", %{"Key" => key}, items) do
    case items[key["id"]["S"]] do
      nil -> {200, %{}, items}
      item -> {200, %{"Item" => item}, items}
    end
  end

  defp handle_op("DeleteItem", %{"Key" => key} = b, items) do
    id = key["id"]["S"]

    if equality_ok?(b, items[id]),
      do: {200, %{}, Map.delete(items, id)},
      else: {400, conditional_failed(), items}
  end

  defp handle_op("UpdateItem", %{"Key" => key, "UpdateExpression" => "SET " <> sets} = b, items) do
    id = key["id"]["S"]
    item = items[id] || key
    names = b["ExpressionAttributeNames"] || %{}
    values = b["ExpressionAttributeValues"] || %{}

    if not equality_ok?(b, items[id]) do
      throw({:conditional, items})
    end

    item =
      sets
      |> String.split(",")
      |> Enum.reduce(item, fn assignment, acc ->
        [lhs, rhs] = assignment |> String.split("=") |> Enum.map(&String.trim/1)
        Map.put(acc, Map.get(names, lhs, lhs), Map.fetch!(values, rhs))
      end)

    {200, %{}, Map.put(items, id, item)}
  end

  defp handle_op(op, _b, items),
    do: {400, %{"__type" => "UnknownOperationException", "message" => op}, items}

  # Supports exactly the expression Mayfly.Idempotency sends.
  defp condition_ok?(nil, _existing, _v, _n), do: true
  defp condition_ok?(_cond, nil, _v, _n), do: true

  defp condition_ok?(cond, existing, values, names) do
    now = values[":now"]["N"] |> String.to_integer()
    status_attr = Map.get(names || %{}, "#s", "status")
    expires = existing["expires_at"]["N"] |> String.to_integer()

    in_progress_until =
      (existing["in_progress_until"] || %{"N" => "0"})["N"] |> String.to_integer()

    status = existing[status_attr]["S"]

    String.contains?(cond, "attribute_not_exists") and
      (expires < now or (status == "INPROGRESS" and in_progress_until < now))
  end

  # -- HTTP --------------------------------------------------------------------------

  defp accept(listen, server) do
    {:ok, sock} = :gen_tcp.accept(listen)
    spawn(fn -> serve(sock, server) end)
    accept(listen, server)
  end

  defp serve(sock, server) do
    {:ok, {:http_request, :POST, _, _}} = :gen_tcp.recv(sock, 0)
    headers = read_headers(sock, %{})
    :inet.setopts(sock, packet: :raw)
    len = headers |> Map.get("content-length", "0") |> String.to_integer()
    {:ok, body} = if len > 0, do: :gen_tcp.recv(sock, len), else: {:ok, ""}

    "DynamoDB_20120810." <> op = Map.fetch!(headers, "x-amz-target")
    # Signature presence is asserted by tests via these headers.
    true = Map.has_key?(headers, "authorization") and Map.has_key?(headers, "x-amz-date")

    {status, resp} = GenServer.call(server, {:op, op, JSON.decode!(body)})
    json = JSON.encode!(resp)

    :gen_tcp.send(
      sock,
      "HTTP/1.1 #{status} X\r\nContent-Type: application/x-amz-json-1.0\r\nContent-Length: #{byte_size(json)}\r\nConnection: close\r\n\r\n#{json}"
    )

    :gen_tcp.close(sock)
  end

  defp read_headers(sock, acc) do
    case :gen_tcp.recv(sock, 0) do
      {:ok, {:http_header, _, name, _, value}} ->
        read_headers(sock, Map.put(acc, name |> to_string() |> String.downcase(), value))

      {:ok, :http_eoh} ->
        acc
    end
  end
end
