defmodule Mayfly.AWS.JSONProtocol do
  @moduledoc false
  # Shared call for AWS JSON-protocol services (SQS, SSM, Secrets Manager):
  # POST to the regional endpoint with X-Amz-Target.

  alias Mayfly.AWS.Request

  @spec call(String.t(), String.t(), String.t(), map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Request.error()}
  def call(service, target_prefix, operation, body, content_type, opts) do
    url =
      Keyword.get(opts, :endpoint) || "https://#{service}.#{Request.region(opts)}.amazonaws.com/"

    payload = JSON.encode!(body)
    headers = [{"content-type", content_type}, {"x-amz-target", "#{target_prefix}.#{operation}"}]

    with {:ok, _status, _h, resp} <- Request.send(service, :post, url, headers, payload, opts) do
      if resp == "", do: {:ok, %{}}, else: {:ok, JSON.decode!(resp)}
    end
  end
end
