defmodule Mayfly.AWS.SigV4 do
  @moduledoc """
  AWS Signature Version 4 for HTTP requests (header-based signing).

      headers = Mayfly.AWS.SigV4.sign(creds, "dynamodb", "eu-central-1", "POST",
        "https://dynamodb.eu-central-1.amazonaws.com/", headers, body)

  Implements the canonical request / string-to-sign / signing-key derivation
  from the SigV4 specification. `x-amz-date`, `host` and (when a session token
  is present) `x-amz-security-token` are added automatically; the returned
  header list includes `authorization`.
  """

  alias Mayfly.AWS.Credentials

  @type headers :: [{String.t(), String.t()}]

  @doc """
  Signs a request and returns the full header list to send. `now` (a
  `DateTime`) is injectable for tests.
  """
  @spec sign(
          Credentials.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          headers(),
          iodata(),
          DateTime.t(),
          keyword()
        ) :: headers()
  def sign(
        %Credentials{} = creds,
        service,
        region,
        method,
        url,
        headers,
        body,
        now \\ DateTime.utc_now(),
        opts \\ []
      ) do
    uri = URI.parse(url)
    amz_date = amz_date(now)
    date = String.slice(amz_date, 0, 8)
    payload_hash = hex(:crypto.hash(:sha256, body))

    content_header =
      if Keyword.get(opts, :content_sha256, true),
        do: [{"x-amz-content-sha256", payload_hash}],
        else: []

    headers =
      headers
      |> Enum.map(fn {k, v} -> {String.downcase(k), String.trim(v)} end)
      |> Enum.reject(fn {k, _} ->
        k in [
          "authorization",
          "x-amz-date",
          "host",
          "x-amz-security-token",
          "x-amz-content-sha256"
        ]
      end)
      |> Kernel.++([{"host", host(uri)}, {"x-amz-date", amz_date}] ++ content_header)
      |> Kernel.++(
        if creds.session_token, do: [{"x-amz-security-token", creds.session_token}], else: []
      )
      |> Enum.sort()

    signed_headers = headers |> Enum.map(&elem(&1, 0)) |> Enum.join(";")

    canonical_request =
      Enum.join(
        [
          String.upcase(method),
          canonical_path(uri.path, service),
          canonical_query(uri.query),
          Enum.map_join(headers, "", fn {k, v} -> "#{k}:#{v}\n" end),
          signed_headers,
          payload_hash
        ],
        "\n"
      )

    scope = "#{date}/#{region}/#{service}/aws4_request"

    string_to_sign =
      Enum.join(
        ["AWS4-HMAC-SHA256", amz_date, scope, hex(:crypto.hash(:sha256, canonical_request))],
        "\n"
      )

    signature =
      hex(hmac(signing_key(creds.secret_access_key, date, region, service), string_to_sign))

    authorization =
      "AWS4-HMAC-SHA256 Credential=#{creds.access_key_id}/#{scope}, SignedHeaders=#{signed_headers}, Signature=#{signature}"

    headers ++ [{"authorization", authorization}]
  end

  @doc false
  def signing_key(secret, date, region, service) do
    ("AWS4" <> secret)
    |> hmac(date)
    |> hmac(region)
    |> hmac(service)
    |> hmac("aws4_request")
  end

  @doc false
  def canonical_path(path, service \\ "")

  def canonical_path(nil, _), do: "/"
  def canonical_path("", _), do: "/"

  # S3 is the exception in the SigV4 spec: the canonical URI is the URL path
  # exactly as sent (already percent-encoded once), not encoded again.
  def canonical_path(path, "s3"), do: path

  def canonical_path(path, _service) do
    # Encode each segment per RFC 3986 (unreserved chars unencoded), keep "/".
    path
    |> String.split("/")
    |> Enum.map_join("/", &uri_encode/1)
  end

  @doc false
  def canonical_query(nil), do: ""
  def canonical_query(""), do: ""

  def canonical_query(query) do
    query
    |> String.split("&", trim: true)
    |> Enum.map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [k, v] -> {uri_encode(URI.decode(k)), uri_encode(URI.decode(v))}
        [k] -> {uri_encode(URI.decode(k)), ""}
      end
    end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
  end

  @doc false
  def uri_encode(str), do: URI.encode(str, &URI.char_unreserved?/1)

  defp host(%URI{host: host, port: port, scheme: scheme}) do
    if (scheme == "https" and port == 443) or (scheme == "http" and port == 80) or is_nil(port),
      do: host,
      else: "#{host}:#{port}"
  end

  defp amz_date(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/[-:]/, "")
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hex(bin), do: Base.encode16(bin, case: :lower)
end
