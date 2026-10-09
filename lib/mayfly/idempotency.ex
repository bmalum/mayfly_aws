defmodule Mayfly.Idempotency do
  @moduledoc """
  Exactly-once semantics for Lambda handlers, backed by a DynamoDB table.

      def handle(event, ctx, _state) do
        Mayfly.Idempotency.run(event, fn -> place_order(event) end, context: ctx)
      end

  `run/3` derives a key from the event (SHA-256 of its JSON by default),
  claims it with a conditional `PutItem`, runs `fun`, and stores the result.
  A later invocation with the same key returns the stored result without
  running `fun` again; a concurrent one gets `{:error, :in_progress}`.

  | Situation | Return |
  |---|---|
  | first call, `fun` returns `{:ok, result}` | `{:ok, result}` (result stored as `COMPLETED`) |
  | same key again within `ttl` | `{:ok, result, :replayed}` |
  | same key while another invocation is running it | `{:error, :in_progress}` |
  | `fun` returns `{:error, reason}` or raises | record deleted, error propagated (`{:error, reason}` / re-raised) so a retry can run |

  ## Table

  Partition key `id` (String); enable TTL on `expires_at`. Minimum IAM:
  `dynamodb:PutItem`, `GetItem`, `UpdateItem`, `DeleteItem` on the table.

      aws dynamodb create-table --table-name idempotency \\
        --attribute-definitions AttributeName=id,AttributeType=S \\
        --key-schema AttributeName=id,KeyType=HASH --billing-mode PAY_PER_REQUEST
      aws dynamodb update-time-to-live --table-name idempotency \\
        --time-to-live-specification Enabled=true,AttributeName=expires_at

  ## Options

    * `:table` – table name (default env `MAYFLY_IDEMPOTENCY_TABLE`)
    * `:key` – explicit key string, or `:key_fun` – `(event -> String.t())`
    * `:ttl` – seconds a completed record is kept (default 3600)
    * `:in_progress_ttl` – seconds an in-progress claim is valid; default is the
      invocation's remaining time from `:context`, else 60
    * `:context` – the `Mayfly.Context`, used for `in_progress_ttl` and stored
      for debugging (`request_id`)
    * `:dynamodb` – options passed to `Mayfly.AWS.DynamoDB` (e.g. `endpoint:`)

  Results must be JSON-encodable; they are stored as JSON and decoded on
  replay, so atom keys come back as strings.
  """

  alias Mayfly.AWS.DynamoDB

  require Logger

  @type result ::
          {:ok, term()} | {:ok, term(), :replayed} | {:error, :in_progress} | {:error, term()}

  @doc "Runs `fun` once per idempotency key. See the module documentation."
  @spec run(term(), (-> {:ok, term()} | {:error, term()}), keyword()) :: result()
  def run(event, fun, opts \\ []) when is_function(fun, 0) do
    table =
      Keyword.get(opts, :table) || System.get_env("MAYFLY_IDEMPOTENCY_TABLE") ||
        raise ArgumentError, "no idempotency table: pass table: or set MAYFLY_IDEMPOTENCY_TABLE"

    key = key(event, opts)
    now = System.system_time(:second)
    ttl = Keyword.get(opts, :ttl, 3600)
    ddb = Keyword.get(opts, :dynamodb, [])
    ctx = Keyword.get(opts, :context)

    in_progress_ttl =
      Keyword.get_lazy(opts, :in_progress_ttl, fn ->
        case ctx && Mayfly.Context.remaining_time_ms(ctx) do
          ms when is_integer(ms) and ms > 0 -> max(div(ms, 1000), 1)
          _ -> 60
        end
      end)

    claim = %{
      "id" => key,
      "status" => "INPROGRESS",
      "expires_at" => now + ttl,
      "in_progress_until" => now + in_progress_ttl,
      "request_id" => ctx && ctx.request_id
    }

    case DynamoDB.put_item(
           table,
           claim,
           [
             condition:
               "attribute_not_exists(id) OR expires_at < :now OR (#s = :inprog AND in_progress_until < :now)",
             names: %{"#s" => "status"},
             values: %{":now" => now, ":inprog" => "INPROGRESS"}
           ] ++ ddb
         ) do
      {:ok, _} ->
        execute(table, key, fun, now + ttl, ddb)

      {:error, :conditional_check_failed} ->
        replay(table, key, ddb)

      {:error, reason} ->
        {:error, {:idempotency_store, reason}}
    end
  end

  @doc "The default key: SHA-256 (hex) of the JSON-encoded event."
  @spec default_key(term()) :: String.t()
  def default_key(event),
    do: :crypto.hash(:sha256, JSON.encode!(event)) |> Base.encode16(case: :lower)

  defp key(event, opts) do
    cond do
      k = Keyword.get(opts, :key) -> to_string(k)
      f = Keyword.get(opts, :key_fun) -> to_string(f.(event))
      true -> default_key(event)
    end
  end

  defp execute(table, key, fun, expires_at, ddb) do
    result =
      try do
        fun.()
      rescue
        e -> {:raised, e, __STACKTRACE__}
      catch
        kind, reason -> {:caught, kind, reason, __STACKTRACE__}
      end

    case result do
      {:ok, value} ->
        DynamoDB.update_item(
          table,
          %{"id" => key},
          [
            update: "SET #s = :done, #r = :result, expires_at = :exp",
            names: %{"#s" => "status", "#r" => "result"},
            values: %{
              ":done" => "COMPLETED",
              ":result" => JSON.encode!(value),
              ":exp" => expires_at
            }
          ] ++ ddb
        )
        |> case do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning("idempotency: could not store result for #{key}: #{inspect(reason)}")
        end

        {:ok, value}

      {:error, _} = error ->
        release(table, key, ddb)
        error

      {:raised, e, st} ->
        release(table, key, ddb)
        reraise e, st

      {:caught, kind, reason, st} ->
        release(table, key, ddb)
        :erlang.raise(kind, reason, st)

      other ->
        release(table, key, ddb)
        {:error, {:invalid_result, other}}
    end
  end

  defp replay(table, key, ddb) do
    case DynamoDB.get_item(table, %{"id" => key}, [consistent: true] ++ ddb) do
      {:ok, %{"status" => "COMPLETED", "result" => json}} -> {:ok, JSON.decode!(json), :replayed}
      {:ok, %{"status" => "INPROGRESS"}} -> {:error, :in_progress}
      # Claim lost the race and the record expired/was deleted in between: treat as in progress.
      {:ok, _} -> {:error, :in_progress}
      {:error, reason} -> {:error, {:idempotency_store, reason}}
    end
  end

  defp release(table, key, ddb) do
    case DynamoDB.delete_item(table, %{"id" => key}, ddb) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("idempotency: could not release #{key}: #{inspect(reason)}")
    end
  end
end
