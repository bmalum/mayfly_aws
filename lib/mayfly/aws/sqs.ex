defmodule Mayfly.AWS.SQS do
  @moduledoc """
  SQS: send, receive, delete, change visibility. Message bodies are strings;
  pass a map to `send_message/3` and it is JSON-encoded.

      {:ok, %{message_id: id}} = SQS.send_message(queue_url, %{"order" => 1})
      {:ok, messages} = SQS.receive_messages(queue_url, max: 10, wait_seconds: 0)
      :ok = SQS.delete_message(queue_url, msg.receipt_handle)

  Inside a Lambda triggered by SQS you normally do not call receive/delete:
  the event source mapping does that (see `Mayfly.Events.SQS`). These are for
  producing messages and for cross-queue work.
  """

  alias Mayfly.AWS.{JSONProtocol, Request}

  @target "AmazonSQS"
  @ct "application/x-amz-json-1.0"

  @type message :: %{
          message_id: String.t(),
          receipt_handle: String.t(),
          body: String.t(),
          attributes: map(),
          message_attributes: map()
        }

  @doc """
  Sends a message. Options: `delay_seconds:`, `group_id:` and `dedup_id:`
  (FIFO queues), `attributes:` (`%{"name" => "string value"}`, sent as
  String attributes).
  """
  @spec send_message(String.t(), String.t() | map() | list(), keyword()) ::
          {:ok, %{message_id: String.t(), md5: String.t()}} | {:error, Request.error()}
  def send_message(queue_url, body, opts \\ []) do
    body = if is_binary(body), do: body, else: JSON.encode!(body)

    params =
      %{"QueueUrl" => queue_url, "MessageBody" => body}
      |> maybe("DelaySeconds", opts[:delay_seconds])
      |> maybe("MessageGroupId", opts[:group_id])
      |> maybe("MessageDeduplicationId", opts[:dedup_id])
      |> maybe("MessageAttributes", string_attributes(opts[:attributes]))

    with {:ok, resp} <- call("SendMessage", params, opts) do
      {:ok, %{message_id: resp["MessageId"], md5: resp["MD5OfMessageBody"]}}
    end
  end

  @doc "Receives up to `max:` (default 1, max 10) messages; `wait_seconds:` long-polls (default 0), `visibility_timeout:`."
  @spec receive_messages(String.t(), keyword()) :: {:ok, [message()]} | {:error, Request.error()}
  def receive_messages(queue_url, opts \\ []) do
    params =
      %{
        "QueueUrl" => queue_url,
        "MaxNumberOfMessages" => Keyword.get(opts, :max, 1),
        "WaitTimeSeconds" => Keyword.get(opts, :wait_seconds, 0),
        "MessageSystemAttributeNames" => ["All"],
        "MessageAttributeNames" => ["All"]
      }
      |> maybe("VisibilityTimeout", opts[:visibility_timeout])

    with {:ok, resp} <- call("ReceiveMessage", params, opts) do
      {:ok,
       for m <- resp["Messages"] || [] do
         %{
           message_id: m["MessageId"],
           receipt_handle: m["ReceiptHandle"],
           body: m["Body"],
           attributes: m["Attributes"] || %{},
           message_attributes:
             Map.new(m["MessageAttributes"] || %{}, fn {k, v} ->
               {k, v["StringValue"] || v["BinaryValue"]}
             end)
         }
       end}
    end
  end

  @doc "Deletes a message by receipt handle."
  @spec delete_message(String.t(), String.t(), keyword()) :: :ok | {:error, Request.error()}
  def delete_message(queue_url, receipt_handle, opts \\ []) do
    with {:ok, _} <-
           call(
             "DeleteMessage",
             %{"QueueUrl" => queue_url, "ReceiptHandle" => receipt_handle},
             opts
           ),
         do: :ok
  end

  @doc "Extends or shortens a message's visibility timeout (seconds)."
  @spec change_visibility(String.t(), String.t(), non_neg_integer(), keyword()) ::
          :ok | {:error, Request.error()}
  def change_visibility(queue_url, receipt_handle, seconds, opts \\ []) do
    params = %{
      "QueueUrl" => queue_url,
      "ReceiptHandle" => receipt_handle,
      "VisibilityTimeout" => seconds
    }

    with {:ok, _} <- call("ChangeMessageVisibility", params, opts), do: :ok
  end

  @doc "Raw SQS operation (JSON protocol)."
  @spec call(String.t(), map(), keyword()) :: {:ok, map()} | {:error, Request.error()}
  def call(operation, params, opts \\ []),
    do: JSONProtocol.call("sqs", @target, operation, params, @ct, opts)

  defp maybe(map, _k, nil), do: map
  defp maybe(map, k, v), do: Map.put(map, k, v)

  defp string_attributes(nil), do: nil

  defp string_attributes(attrs),
    do:
      Map.new(attrs, fn {k, v} ->
        {to_string(k), %{"DataType" => "String", "StringValue" => to_string(v)}}
      end)
end
