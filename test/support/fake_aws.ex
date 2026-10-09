defmodule Mayfly.AWS.FakeAWS do
  @moduledoc """
  Generic HTTP stub for the service clients: records every request (method,
  path, query, headers, body) and answers with a canned `{status, headers, body}`
  provided per request via a responder function. Asserts that requests carry a
  SigV4 `authorization` header.
  """
  use GenServer

  def start_link(responder), do: GenServer.start_link(__MODULE__, responder)
  def endpoint(pid), do: "http://127.0.0.1:#{GenServer.call(pid, :port)}"
  def requests(pid), do: GenServer.call(pid, :requests)
  def last(pid), do: pid |> requests() |> List.last()

  @impl true
  def init(responder) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    server = self()
    spawn_link(fn -> accept(listen, server) end)
    {:ok, %{port: port, responder: responder, requests: []}}
  end

  @impl true
  def handle_call(:port, _f, s), do: {:reply, s.port, s}
  def handle_call(:requests, _f, s), do: {:reply, Enum.reverse(s.requests), s}

  def handle_call({:request, req}, _f, s) do
    true =
      Map.has_key?(req.headers, "authorization") or
        raise("unsigned request #{req.method} #{req.path}")

    {:reply, s.responder.(req), %{s | requests: [req | s.requests]}}
  end

  defp accept(listen, server) do
    {:ok, sock} = :gen_tcp.accept(listen)
    spawn(fn -> serve(sock, server) end)
    accept(listen, server)
  end

  defp serve(sock, server) do
    {:ok, head, rest} = read_head(sock, "")
    [request_line | header_lines] = String.split(head, "\r\n")
    [method, target, _] = String.split(request_line, " ", parts: 3)

    headers =
      Map.new(header_lines, fn l ->
        [k, v] = String.split(l, ":", parts: 2)
        {String.downcase(k), String.trim(v)}
      end)

    len = headers |> Map.get("content-length", "0") |> String.to_integer()
    {:ok, body} = read_exact(sock, rest, len)
    %URI{path: path, query: query} = URI.parse(target)

    req = %{
      method: method,
      path: path,
      query: URI.decode_query(query || ""),
      headers: headers,
      body: body
    }

    {status, resp_headers, resp_body} = GenServer.call(server, {:request, req})
    hdrs = Enum.map_join(resp_headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end)

    :gen_tcp.send(
      sock,
      "HTTP/1.1 #{status} X\r\n#{hdrs}Content-Length: #{byte_size(resp_body)}\r\nConnection: close\r\n\r\n#{resp_body}"
    )

    :gen_tcp.close(sock)
  end

  defp read_head(sock, buf) do
    case :binary.split(buf, "\r\n\r\n") do
      [h, rest] -> {:ok, h, rest}
      _ -> with {:ok, d} <- :gen_tcp.recv(sock, 0, 5_000), do: read_head(sock, buf <> d)
    end
  end

  defp read_exact(_s, buf, len) when byte_size(buf) >= len, do: {:ok, binary_part(buf, 0, len)}

  defp read_exact(sock, buf, len),
    do: with({:ok, d} <- :gen_tcp.recv(sock, 0, 5_000), do: read_exact(sock, buf <> d, len))
end
