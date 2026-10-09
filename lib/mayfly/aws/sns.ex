defmodule Mayfly.AWS.SNS do
  @moduledoc """
  SNS publish (Query protocol).

      {:ok, %{message_id: id}} = SNS.publish(topic_arn, %{"event" => "order.placed", "id" => 1}, subject: "order")

  Maps are JSON-encoded. `attributes:` become String message attributes
  (useful for subscription filter policies). `target_arn:`/`phone_number:`
  can replace the topic ARN; FIFO topics take `group_id:`/`dedup_id:`.
  """

  alias Mayfly.AWS.Request

  @doc "Publishes `message` (string, or a map/list that is JSON-encoded) to a topic ARN."
  @spec publish(String.t(), String.t() | map() | list(), keyword()) ::
          {:ok, %{message_id: String.t(), sequence_number: String.t() | nil}}
          | {:error, Request.error()}
  def publish(topic_arn, message, opts \\ []) do
    message = if is_binary(message), do: message, else: JSON.encode!(message)

    params =
      %{"Action" => "Publish", "Version" => "2010-03-31", "Message" => message}
      |> Map.merge(target(topic_arn, opts))
      |> maybe("Subject", opts[:subject])
      |> maybe("MessageGroupId", opts[:group_id])
      |> maybe("MessageDeduplicationId", opts[:dedup_id])
      |> Map.merge(attributes(Keyword.get(opts, :attributes, %{})))

    url = Keyword.get(opts, :endpoint) || "https://sns.#{Request.region(opts)}.amazonaws.com/"
    body = Request.form(params)
    headers = [{"content-type", "application/x-www-form-urlencoded; charset=utf-8"}]

    with {:ok, _, _, xml} <- Request.send("sns", :post, url, headers, body, opts) do
      {:ok,
       %{
         message_id: Request.xml_tag(xml, "MessageId"),
         sequence_number: Request.xml_tag(xml, "SequenceNumber")
       }}
    end
  end

  defp target(topic_arn, opts) do
    cond do
      opts[:phone_number] -> %{"PhoneNumber" => opts[:phone_number]}
      opts[:target_arn] -> %{"TargetArn" => opts[:target_arn]}
      true -> %{"TopicArn" => topic_arn}
    end
  end

  defp attributes(attrs) do
    attrs
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {{k, v}, i} ->
      [
        {"MessageAttributes.entry.#{i}.Name", to_string(k)},
        {"MessageAttributes.entry.#{i}.Value.DataType", "String"},
        {"MessageAttributes.entry.#{i}.Value.StringValue", to_string(v)}
      ]
    end)
    |> Map.new()
  end

  defp maybe(map, _k, nil), do: map
  defp maybe(map, k, v), do: Map.put(map, k, v)
end
