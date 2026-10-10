defmodule Mayfly.AWS.HTTP do
  @moduledoc """
  HTTPS via `:httpc`, with `:inets`/`:ssl` started on first use so they cost
  nothing until an AWS call is actually made (roughly 60–80 ms once per
  execution environment). TLS verifies the server certificate against the OTP
  CA bundle (`:public_key.cacerts_get/0`).
  """

  @timeout_ms 10_000

  @type response :: {:ok, 100..599, binary()} | {:error, term()}
  @type response_with_headers ::
          {:ok, 100..599, [{String.t(), String.t()}], binary()} | {:error, term()}

  @doc "POSTs `body` with `headers`; returns `{:ok, status, body}` or `{:error, reason}`."
  @spec post(String.t(), [{String.t(), String.t()}], iodata(), keyword()) :: response()
  def post(url, headers, body, opts \\ []) do
    case request(:post, url, headers, body, opts) do
      {:ok, status, _headers, resp_body} -> {:ok, status, resp_body}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Any method. Returns `{:ok, status, response_headers, body}` or `{:error, reason}`.
  Response header names are lowercased.
  """
  @spec request(
          :get | :put | :post | :delete | :head,
          String.t(),
          [{String.t(), String.t()}],
          iodata(),
          keyword()
        ) ::
          response_with_headers()
  def request(method, url, headers, body, opts \\ []) do
    ensure_started()

    {content_type, headers} =
      List.keytake(headers, "content-type", 0) ||
        {{"content-type", "application/octet-stream"}, headers}

    charlist_headers = for {k, v} <- headers, do: {String.to_charlist(k), String.to_charlist(v)}

    request =
      if method in [:get, :head, :delete] and IO.iodata_length(body) == 0 do
        {String.to_charlist(url), charlist_headers}
      else
        {String.to_charlist(url), charlist_headers, String.to_charlist(elem(content_type, 1)),
         IO.iodata_to_binary(body)}
      end

    http_opts = [
      timeout: Keyword.get(opts, :timeout, @timeout_ms),
      connect_timeout: 3_000,
      ssl: ssl_options(url)
    ]

    case :httpc.request(method, request, http_opts, body_format: :binary) do
      {:ok, {{_, status, _}, resp_headers, resp_body}} ->
        headers =
          for {k, v} <- resp_headers, do: {k |> to_string() |> String.downcase(), to_string(v)}

        {:ok, status, headers, resp_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ssl_options("http://" <> _), do: []

  defp ssl_options(_https) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp ensure_started do
    # :ssl/:inets are declared with `:load` (not started) in mix.exs so they cost
    # nothing at boot; the first AWS call starts them.
    for app <- [:crypto, :asn1, :public_key, :ssl, :inets] do
      {:ok, _} = Application.ensure_all_started(app)
    end

    :ok
  end
end
