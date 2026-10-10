# Mayfly.AWS

Companion package for [Mayfly](https://elixir-aws-lambda.dev) (Elixir on AWS
Lambda): the handful of AWS calls most Lambda functions actually make, with no
dependencies beyond OTP (`:inets`/`:ssl` for TLS, ~20 ms to start once at boot):

| Module | Operations |
|---|---|
| `Mayfly.Idempotency` | exactly-once handler execution on DynamoDB |
| `Mayfly.AWS.DynamoDB` | PutItem, GetItem, UpdateItem, DeleteItem, raw `request/3` |
| `Mayfly.AWS.S3` | put/get/head/delete object, ListObjectsV2, presigned GET/PUT URLs |
| `Mayfly.AWS.SQS` | send, receive, delete, change visibility |
| `Mayfly.AWS.SNS` | publish (topic, target or phone number, message attributes) |
| `Mayfly.AWS.SSM` | get_parameter(s), get_parameters_by_path (paginated, decrypting) |
| `Mayfly.AWS.SecretsManager` | get_secret_value, get_secret_json |

Not a general AWS SDK: every function here was verified against the real
service from a Lambda function. For the long tail, `Mayfly.AWS.SigV4.sign/9`
signs any request.

It lives outside the core `mayfly` package so the runtime itself stays free of
`:ssl` and keeps its cold start.

```elixir
def deps do
  [{:mayfly, "~> 1.0.0-rc"}, {:mayfly_aws, "~> 0.1"}]
end
```

## Idempotency

```elixir
defmodule MyApp.Handler do
  use Mayfly.Handler

  @impl true
  def handle(%{"orderId" => id} = event, ctx, _state) do
    case Mayfly.Idempotency.run(event, fn -> place_order(event) end,
           key_fun: &("order-" <> &1["orderId"]), context: ctx, ttl: 3600) do
      {:ok, order} -> {:ok, %{status: "placed", order: order}}
      {:ok, order, :replayed} -> {:ok, %{status: "replayed", order: order}}
      {:error, :in_progress} -> {:error, %{errorType: "InProgress", errorMessage: "retry later"}}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

| Situation | Result |
|---|---|
| first call, `fun` returns `{:ok, r}` | `{:ok, r}`, stored as `COMPLETED` |
| same key again within `ttl` | `{:ok, r, :replayed}` – `fun` not called |
| same key while another invocation runs it | `{:error, :in_progress}` |
| `fun` returns `{:error, _}` or raises | record released, error propagated, retry runs `fun` again |
| in-progress claim older than `in_progress_ttl` (default: invocation deadline) | taken over |

Table: partition key `id` (S), TTL on `expires_at`. Set `MAYFLY_IDEMPOTENCY_TABLE`
or pass `table:`. IAM: `dynamodb:PutItem`, `GetItem`, `UpdateItem`,
`DeleteItem` on the table.

```bash
aws dynamodb create-table --table-name idempotency \
  --attribute-definitions AttributeName=id,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH --billing-mode PAY_PER_REQUEST
aws dynamodb update-time-to-live --table-name idempotency \
  --time-to-live-specification Enabled=true,AttributeName=expires_at
```

Results are stored as JSON, so replayed results have string keys.

## Services

```elixir
alias Mayfly.AWS.{S3, SQS, SNS, SSM, SecretsManager}

# fetch configuration once per environment
def init(_opts) do
  config = SSM.get_parameters_by_path!("/myapp/prod/", strip_prefix: true)
  {:ok, db} = SecretsManager.get_secret_json("prod/db")
  {:ok, %{config: config, db: db}}
end

{:ok, %{etag: _}} = S3.put_object("bucket", "reports/1.json", JSON.encode!(r), content_type: "application/json")
{:ok, body, _headers} = S3.get_object("bucket", "reports/1.json")
url = S3.presign(:get, "bucket", "reports/1.json", expires_in: 300)
{:ok, %{message_id: _}} = SQS.send_message(queue_url, %{"order" => 1}, attributes: %{source: "api"})
{:ok, %{message_id: _}} = SNS.publish(topic_arn, %{"event" => "order.placed"}, subject: "order")
```

Errors are `{:error, {code, message}}` with the service's error code
(`"AccessDenied"`, `"QueueDoesNotExist"`, `"ParameterNotFound"`, …) or a
transport reason. `endpoint:` on every call points at LocalStack/MinIO or a
test server; `region:` overrides `AWS_REGION`.

## DynamoDB client

```elixir
alias Mayfly.AWS.DynamoDB
{:ok, _} = DynamoDB.put_item("orders", %{"id" => "o1", "total" => 12.5, "tags" => ["a"]},
             condition: "attribute_not_exists(id)")
{:ok, %{"id" => "o1", "total" => 12.5}} = DynamoDB.get_item("orders", %{"id" => "o1"}, consistent: true)
{:ok, _} = DynamoDB.update_item("orders", %{"id" => "o1"}, update: "SET #s = :s", names: %{"#s" => "status"}, values: %{":s" => "shipped"})
{:ok, _} = DynamoDB.delete_item("orders", %{"id" => "o1"})
```

Plain maps in, plain maps out (attribute values converted both ways).
Conditional failures are `{:error, :conditional_check_failed}`. `request/3`
exposes any other operation. `endpoint:` points at DynamoDB Local or a test
server.

## Signing

`Mayfly.AWS.SigV4.sign/9` signs arbitrary requests (tested against the AWS
SigV4 test-suite vectors); `Mayfly.AWS.Credentials.from_env/0` reads the
credentials Lambda provides.

## Tests

`mix test` runs against an in-memory DynamoDB (`Mayfly.AWS.FakeDynamoDB`) that
implements the conditional semantics used here; no AWS account needed.

MIT. Part of the Mayfly project by [Karrer](https://karrer.solutions).
