defmodule Mayfly.AWS.Request do
  @moduledoc """
  Shared sign-and-send for the service clients: credentials from the
  environment, SigV4 headers, one HTTP call, uniform error shape. Use `send/6`
  to call any AWS API the dedicated modules do not cover.

  Errors are `{:error, {code, message}}` where `code` is the service's error
  code (`"AccessDenied"`, `"ParameterNotFound"`, `"HTTP500"` when none was
  returned) or `{:error, reason}` for transport failures.
  """

  @typedoc "`{code, message}` from the service, or a transport reason."

  alias Mayfly.AWS.{Credentials, HTTP, SigV4}

  @type error :: {String.t() | nil, String.t()} | term()

  @doc """
  Signs and sends. Returns `{:ok, status, headers, body}` for any 2xx and
  `{:error, {code, message}}` otherwise (code/message parsed from JSON or XML
  error bodies when possible).
  """
  @spec send(
          String.t(),
          :get | :put | :post | :delete | :head,
          String.t(),
          [{String.t(), String.t()}],
          iodata(),
          keyword()
        ) ::
          {:ok, 200..299, [{String.t(), String.t()}], binary()} | {:error, error()}
  def send(service, method, url, headers, body, opts) do
    with {:ok, creds} <- Credentials.from_env() do
      region = Keyword.get(opts, :region, creds.region)

      signed =
        SigV4.sign(
          creds,
          service,
          region,
          method |> to_string() |> String.upcase(),
          url,
          headers,
          body
        )

      case HTTP.request(method, url, signed, body, opts) do
        {:ok, status, resp_headers, resp_body} when status in 200..299 ->
          {:ok, status, resp_headers, resp_body}

        {:ok, status, _h, resp_body} ->
          {:error, parse_error(status, resp_body)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Region from the credentials/env, or the `:region` option."
  @spec region(keyword()) :: String.t()
  def region(opts) do
    Keyword.get(opts, :region) || System.get_env("AWS_REGION") ||
      System.get_env("AWS_DEFAULT_REGION") ||
      "us-east-1"
  end

  @doc false
  def parse_error(status, body) do
    cond do
      String.starts_with?(body, "{") ->
        case JSON.decode(body) do
          {:ok, %{} = m} ->
            code = m["__type"] || m["code"] || m["Code"] || "HTTP#{status}"

            {code |> to_string() |> String.split("#") |> List.last(),
             m["message"] || m["Message"] || body}

          _ ->
            {"HTTP#{status}", body}
        end

      String.contains?(body, "<Code>") ->
        {xml_tag(body, "Code") || "HTTP#{status}", xml_tag(body, "Message") || body}

      true ->
        {"HTTP#{status}", body}
    end
  end

  @doc "First `<tag>…</tag>` text in an XML document, or nil."
  @spec xml_tag(binary(), String.t()) :: String.t() | nil
  def xml_tag(xml, tag) do
    case Regex.run(~r/<#{tag}>(.*?)<\/#{tag}>/s, xml) do
      [_, text] -> unescape(text)
      nil -> nil
    end
  end

  @doc "All `<tag>…</tag>` texts in document order."
  @spec xml_tags(binary(), String.t()) :: [String.t()]
  def xml_tags(xml, tag) do
    Regex.scan(~r/<#{tag}>(.*?)<\/#{tag}>/s, xml) |> Enum.map(fn [_, t] -> unescape(t) end)
  end

  @doc "Repeated element blocks `<tag>…</tag>` (raw inner XML)."
  @spec xml_blocks(binary(), String.t()) :: [binary()]
  def xml_blocks(xml, tag) do
    Regex.scan(~r/<#{tag}>(.*?)<\/#{tag}>/s, xml) |> Enum.map(fn [_, t] -> t end)
  end

  defp unescape(s) do
    s
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end

  @doc "Form-encodes a map for Query-protocol services (SQS legacy, SNS)."
  @spec form(map()) :: String.t()
  def form(params) do
    params
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} ->
      "#{SigV4.uri_encode(to_string(k))}=#{SigV4.uri_encode(to_string(v))}"
    end)
  end
end
