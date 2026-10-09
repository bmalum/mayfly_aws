defmodule Mayfly.IdempotencyTest do
  use ExUnit.Case, async: false

  alias Mayfly.AWS.{DynamoDB, FakeDynamoDB}
  alias Mayfly.Idempotency

  setup do
    System.put_env("AWS_ACCESS_KEY_ID", "AKIDTEST")
    System.put_env("AWS_SECRET_ACCESS_KEY", "secret")
    System.put_env("AWS_REGION", "eu-central-1")
    {:ok, fake} = FakeDynamoDB.start_link()

    on_exit(fn ->
      for v <- ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION), do: System.delete_env(v)
    end)

    %{fake: fake, opts: [table: "idem", dynamodb: [endpoint: FakeDynamoDB.endpoint(fake)]]}
  end

  test "DynamoDB client round trip with plain terms", %{opts: opts} do
    ddb = opts[:dynamodb]

    item = %{
      "id" => "k1",
      "n" => 3,
      "f" => 1.5,
      "b" => true,
      "nil" => nil,
      "l" => [1, "x"],
      "m" => %{"a" => "b"}
    }

    assert {:ok, _} = DynamoDB.put_item("t", item, ddb)
    assert {:ok, ^item} = DynamoDB.get_item("t", %{"id" => "k1"}, ddb)
    assert {:ok, nil} = DynamoDB.get_item("t", %{"id" => "missing"}, ddb)
    assert {:ok, _} = DynamoDB.delete_item("t", %{"id" => "k1"}, ddb)
    assert {:ok, nil} = DynamoDB.get_item("t", %{"id" => "k1"}, ddb)
    assert {:error, {"UnknownOperationException", "Nope"}} = DynamoDB.request("Nope", %{}, ddb)
  end

  test "first run executes and stores COMPLETED; second run replays", %{fake: fake, opts: opts} do
    counter = :counters.new(1, [])
    event = %{"order" => 1}

    fun = fn ->
      :counters.add(counter, 1, 1)
      {:ok, %{"placed" => true, "n" => :counters.get(counter, 1)}}
    end

    assert {:ok, %{"placed" => true, "n" => 1}} = Idempotency.run(event, fun, opts)
    assert {:ok, %{"placed" => true, "n" => 1}, :replayed} = Idempotency.run(event, fun, opts)
    assert :counters.get(counter, 1) == 1

    [{_key, stored}] = Map.to_list(FakeDynamoDB.items(fake))
    assert stored["status"] == %{"S" => "COMPLETED"}
    assert stored["result"]["S"] |> JSON.decode!() == %{"placed" => true, "n" => 1}
    assert String.to_integer(stored["expires_at"]["N"]) > System.system_time(:second)
  end

  test "default key is sha256 of the JSON event; explicit key and key_fun are honoured", %{
    fake: fake,
    opts: opts
  } do
    assert {:ok, 1} = Idempotency.run(%{"a" => 1}, fn -> {:ok, 1} end, opts)
    assert Map.keys(FakeDynamoDB.items(fake)) == [Idempotency.default_key(%{"a" => 1})]

    assert {:ok, 2} = Idempotency.run(%{"a" => 2}, fn -> {:ok, 2} end, opts ++ [key: "custom"])

    assert {:ok, 2, :replayed} =
             Idempotency.run(
               %{"totally" => "different"},
               fn -> {:ok, 99} end,
               opts ++ [key: "custom"]
             )

    assert {:ok, 3} =
             Idempotency.run(
               %{"orderId" => "o-9"},
               fn -> {:ok, 3} end,
               opts ++ [key_fun: & &1["orderId"]]
             )

    assert Map.has_key?(FakeDynamoDB.items(fake), "o-9")
  end

  test "{:error, _} releases the record so the next attempt runs", %{fake: fake, opts: opts} do
    assert {:error, :db_down} = Idempotency.run(%{"x" => 1}, fn -> {:error, :db_down} end, opts)
    assert FakeDynamoDB.items(fake) == %{}
    assert {:ok, :fine} = Idempotency.run(%{"x" => 1}, fn -> {:ok, :fine} end, opts)
  end

  test "raise and throw release the record and propagate", %{fake: fake, opts: opts} do
    assert_raise ArgumentError, "boom", fn ->
      Idempotency.run(%{"x" => 2}, fn -> raise ArgumentError, "boom" end, opts)
    end

    assert FakeDynamoDB.items(fake) == %{}
    assert catch_throw(Idempotency.run(%{"x" => 2}, fn -> throw(:ball) end, opts)) == :ball
    assert FakeDynamoDB.items(fake) == %{}
  end

  test "a non-conforming result releases and returns an error", %{fake: fake, opts: opts} do
    assert {:error, {:invalid_result, :oops}} =
             Idempotency.run(%{"x" => 3}, fn -> :oops end, opts)

    assert FakeDynamoDB.items(fake) == %{}
  end

  test "concurrent claim while in progress returns :in_progress", %{opts: opts} do
    parent = self()
    event = %{"slow" => true}

    slow =
      Task.async(fn ->
        Idempotency.run(
          event,
          fn ->
            send(parent, :started)
            receive do: (:go -> {:ok, :slow_done})
          end,
          opts
        )
      end)

    assert_receive :started
    assert {:error, :in_progress} = Idempotency.run(event, fn -> {:ok, :never} end, opts)
    send(slow.pid, :go)
    assert {:ok, :slow_done} = Task.await(slow)
    assert {:ok, "slow_done", :replayed} = Idempotency.run(event, fn -> {:ok, :never} end, opts)
  end

  test "an expired in-progress claim can be taken over", %{fake: fake, opts: opts} do
    past = System.system_time(:second) - 10

    FakeDynamoDB.put_raw(fake, %{
      "id" => %{"S" => "stale"},
      "status" => %{"S" => "INPROGRESS"},
      "expires_at" => %{"N" => "#{past + 3600}"},
      "in_progress_until" => %{"N" => "#{past}"}
    })

    assert {:ok, :taken} = Idempotency.run(%{}, fn -> {:ok, :taken} end, opts ++ [key: "stale"])
  end

  test "an expired completed record is executed again", %{fake: fake, opts: opts} do
    past = System.system_time(:second) - 10

    FakeDynamoDB.put_raw(fake, %{
      "id" => %{"S" => "old"},
      "status" => %{"S" => "COMPLETED"},
      "result" => %{"S" => "1"},
      "expires_at" => %{"N" => "#{past}"},
      "in_progress_until" => %{"N" => "#{past}"}
    })

    assert {:ok, :fresh} = Idempotency.run(%{}, fn -> {:ok, :fresh} end, opts ++ [key: "old"])
  end

  test "in_progress_ttl derives from the context deadline", %{fake: fake, opts: opts} do
    ctx = %Mayfly.Context{
      request_id: "r1",
      deadline_ms: System.system_time(:millisecond) + 20_000
    }

    now = System.system_time(:second)

    assert {:ok, :ok} =
             Idempotency.run(%{}, fn -> {:ok, :ok} end, opts ++ [key: "ctx", context: ctx])

    stored = FakeDynamoDB.items(fake)["ctx"]
    assert stored["request_id"] == %{"S" => "r1"}
    assert String.to_integer(stored["in_progress_until"]["N"]) in (now + 18)..(now + 21)
  end

  test "missing table configuration raises" do
    System.delete_env("MAYFLY_IDEMPOTENCY_TABLE")

    assert_raise ArgumentError, ~r/no idempotency table/, fn ->
      Idempotency.run(%{}, fn -> {:ok, 1} end, [])
    end
  end
end
