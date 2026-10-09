defmodule Mayfly.AWS.S3 do
  @moduledoc """
  Minimal S3 client: objects in and out, a listing, and presigned URLs.

      {:ok, _} = S3.put_object("my-bucket", "reports/2026.json", JSON.encode!(report), content_type: "application/json")
      {:ok, body, headers} = S3.get_object("my-bucket", "reports/2026.json")
      {:ok, keys} = S3.list_objects("my-bucket", prefix: "reports/")
      url = S3.presign(:get, "my-bucket", "reports/2026.json", expires_in: 300)

  Uses virtual-hosted-style URLs (`https://bucket.s3.region.amazonaws.com/key`)
  and the credentials/region from the Lambda environment. `endpoint:` points
  at a local S3 (MinIO, LocalStack) or a test server; with an endpoint the
  path style `endpoint/bucket/key` is used. Bodies are sent with
  `x-amz-content-sha256` (unsigned-payload streaming is not supported; keep
  objects within Lambda's memory).
  """

  alias Mayfly.AWS.{Credentials, Request, SigV4}

  @type headers :: [{String.t(), String.t()}]
  @type error :: Request.error()

  @doc """
  Uploads `body`. Options: `content_type:` (default `application/octet-stream`),
  `metadata:` (map → `x-amz-meta-*`), `storage_class:`, `cache_control:`,
  `acl:`, plus `region:`/`endpoint:`. Returns `{:ok, %{etag: ...}}`.
  """
  @spec put_object(String.t(), String.t(), iodata(), keyword()) ::
          {:ok, %{etag: String.t() | nil}} | {:error, error()}
  def put_object(bucket, key, body, opts \\ []) do
    headers =
      [{"content-type", Keyword.get(opts, :content_type, "application/octet-stream")}] ++
        for({k, v} <- Keyword.get(opts, :metadata, %{}), do: {"x-amz-meta-#{k}", to_string(v)}) ++
        optional_header("x-amz-storage-class", opts[:storage_class]) ++
        optional_header("cache-control", opts[:cache_control]) ++
        optional_header("x-amz-acl", opts[:acl])

    with {:ok, _status, resp_headers, _} <-
           Request.send("s3", :put, url(bucket, key, opts), headers, body, opts) do
      {:ok, %{etag: header(resp_headers, "etag")}}
    end
  end

  @doc "Downloads an object: `{:ok, body, response_headers}`. Option `range: \"bytes=0-99\"`."
  @spec get_object(String.t(), String.t(), keyword()) ::
          {:ok, binary(), headers()} | {:error, error()}
  def get_object(bucket, key, opts \\ []) do
    headers = optional_header("range", opts[:range])

    with {:ok, _status, resp_headers, body} <-
           Request.send("s3", :get, url(bucket, key, opts), headers, "", opts) do
      {:ok, body, resp_headers}
    end
  end

  @doc "HEAD: `{:ok, %{size: bytes, content_type: ..., etag: ..., last_modified: ..., metadata: %{}}}` or `{:error, {\"NotFound\", _}}`."
  @spec head_object(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def head_object(bucket, key, opts \\ []) do
    case Request.send("s3", :head, url(bucket, key, opts), [], "", opts) do
      {:ok, _status, h, _} ->
        {:ok,
         %{
           size: h |> header("content-length") |> then(&(&1 && String.to_integer(&1))),
           content_type: header(h, "content-type"),
           etag: header(h, "etag"),
           last_modified: header(h, "last-modified"),
           metadata: for({"x-amz-meta-" <> k, v} <- h, into: %{}, do: {k, v})
         }}

      {:error, {"HTTP404", _}} ->
        {:error, {"NotFound", "no object #{bucket}/#{key}"}}

      other ->
        other
    end
  end

  @doc "Deletes an object (S3 returns 204 whether or not it existed)."
  @spec delete_object(String.t(), String.t(), keyword()) :: :ok | {:error, error()}
  def delete_object(bucket, key, opts \\ []) do
    with {:ok, _, _, _} <- Request.send("s3", :delete, url(bucket, key, opts), [], "", opts),
         do: :ok
  end

  @doc """
  Lists objects (ListObjectsV2, one page). Options: `prefix:`, `max_keys:`
  (default 1000), `continuation_token:`. Returns
  `{:ok, [%{key:, size:, etag:, last_modified:}], %{truncated?: bool, next_token: ... | nil}}`.
  """
  @spec list_objects(String.t(), keyword()) :: {:ok, [map()], map()} | {:error, error()}
  def list_objects(bucket, opts \\ []) do
    query =
      [{"list-type", "2"}, {"max-keys", to_string(Keyword.get(opts, :max_keys, 1000))}] ++
        if(opts[:prefix], do: [{"prefix", opts[:prefix]}], else: []) ++
        if(opts[:continuation_token],
          do: [{"continuation-token", opts[:continuation_token]}],
          else: []
        )

    url =
      url(bucket, nil, opts) <>
        "?" <> Enum.map_join(query, "&", fn {k, v} -> "#{k}=#{SigV4.uri_encode(v)}" end)

    with {:ok, _, _, xml} <- Request.send("s3", :get, url, [], "", opts) do
      objects =
        for block <- Request.xml_blocks(xml, "Contents") do
          %{
            key: Request.xml_tag(block, "Key"),
            size: block |> Request.xml_tag("Size") |> then(&(&1 && String.to_integer(&1))),
            etag: Request.xml_tag(block, "ETag"),
            last_modified: Request.xml_tag(block, "LastModified")
          }
        end

      {:ok, objects,
       %{
         truncated?: Request.xml_tag(xml, "IsTruncated") == "true",
         next_token: Request.xml_tag(xml, "NextContinuationToken")
       }}
    end
  end

  @doc """
  Presigned URL (query-string SigV4) for `:get` or `:put`. Options:
  `expires_in:` seconds (default 900, max 604800), `content_type:` (PUT; the
  client must then send the same header), `region:`, `endpoint:`.
  Returns the URL string; raises if credentials are missing.
  """
  @spec presign(:get | :put, String.t(), String.t(), keyword()) :: String.t()
  def presign(method, bucket, key, opts \\ []) do
    creds = Credentials.from_env!()
    region = Keyword.get(opts, :region, creds.region)
    expires = Keyword.get(opts, :expires_in, 900)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    date = String.slice(amz_date, 0, 8)
    scope = "#{date}/#{region}/s3/aws4_request"
    base = url(bucket, key, opts)
    %URI{host: host, path: path} = URI.parse(base)

    signed_headers =
      [{"host", host}] ++
        if(method == :put and opts[:content_type],
          do: [{"content-type", opts[:content_type]}],
          else: []
        )

    signed_headers = Enum.sort(signed_headers)

    query =
      [
        {"X-Amz-Algorithm", "AWS4-HMAC-SHA256"},
        {"X-Amz-Credential", "#{creds.access_key_id}/#{scope}"},
        {"X-Amz-Date", amz_date},
        {"X-Amz-Expires", to_string(expires)},
        {"X-Amz-SignedHeaders", Enum.map_join(signed_headers, ";", &elem(&1, 0))}
      ] ++ if(creds.session_token, do: [{"X-Amz-Security-Token", creds.session_token}], else: [])

    canonical_query =
      query
      |> Enum.sort()
      |> Enum.map_join("&", fn {k, v} -> "#{SigV4.uri_encode(k)}=#{SigV4.uri_encode(v)}" end)

    canonical_request =
      Enum.join(
        [
          method |> to_string() |> String.upcase(),
          SigV4.canonical_path(path),
          canonical_query,
          Enum.map_join(signed_headers, "", fn {k, v} -> "#{k}:#{v}\n" end),
          Enum.map_join(signed_headers, ";", &elem(&1, 0)),
          "UNSIGNED-PAYLOAD"
        ],
        "\n"
      )

    string_to_sign =
      Enum.join(["AWS4-HMAC-SHA256", amz_date, scope, sha256_hex(canonical_request)], "\n")

    key = SigV4.signing_key(creds.secret_access_key, date, region, "s3")
    signature = :crypto.mac(:hmac, :sha256, key, string_to_sign) |> Base.encode16(case: :lower)
    base <> "?" <> canonical_query <> "&X-Amz-Signature=" <> signature
  end

  # -- helpers ----------------------------------------------------------------

  @doc false
  def url(bucket, key, opts) do
    path = if key, do: "/" <> encode_key(key), else: "/"

    case Keyword.get(opts, :endpoint) do
      nil -> "https://#{bucket}.s3.#{Request.region(opts)}.amazonaws.com#{path}"
      endpoint -> String.trim_trailing(endpoint, "/") <> "/" <> bucket <> path
    end
  end

  defp encode_key(key), do: key |> String.split("/") |> Enum.map_join("/", &SigV4.uri_encode/1)

  defp optional_header(_name, nil), do: []
  defp optional_header(name, value), do: [{name, to_string(value)}]

  defp header(headers, name), do: Enum.find_value(headers, fn {k, v} -> k == name && v end)

  defp sha256_hex(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
