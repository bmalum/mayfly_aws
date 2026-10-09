defmodule Mayfly.AWS.HTTP do
  @moduledoc """
  HTTPS POST via `:httpc`, with `:inets`/`:ssl` started on first use so they
  cost nothing until an AWS call is actually made (roughly 60–80 ms once per
  execution environment). TLS verifies the server certificate against the
  OTP CA bundle (`:public_key.cacerts_get/0`).
  """

  @timeout_ms 10_000

  @doc "POSTs `body` with `headers`; returns `{:ok, status, body}` or `{:error, reason}`."
  @spec post(String.t(), [{String.t(), String.t()}], iodata(), keyword()) ::
          {:ok, 100..599, binary()} | {:error, term()}
  def post(url, headers, body, opts \\ []) do
    ensure_started()

    {content_type, headers} =
      List.keytake(headers, "content-type", 0) || {{"content-type", "application/json"}, headers}

    charlist_headers = for {k, v} <- headers, do: {String.to_charlist(k), String.to_charlist(v)}

    request =
      {String.to_charlist(url), charlist_headers, String.to_charlist(elem(content_type, 1)),
       IO.iodata_to_binary(body)}

    http_opts = [
      timeout: Keyword.get(opts, :timeout, @timeout_ms),
      connect_timeout: 3_000,
      ssl: ssl_options(url)
    ]

    case :httpc.request(:post, request, http_opts, body_format: :binary) do
      {:ok, {{_, status, _}, _resp_headers, resp_body}} -> {:ok, status, resp_body}
      {:error, reason} -> {:error, reason}
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
    for app <- [:crypto, :asn1, :public_key, :ssl, :inets] do
      {:ok, _} = Application.ensure_all_started(app)
    end

    :ok
  end
end
