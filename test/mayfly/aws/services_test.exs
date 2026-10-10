defmodule Mayfly.AWS.ServicesTest do
  use ExUnit.Case, async: false

  alias Mayfly.AWS.{FakeAWS, S3, SQS, SNS, SSM, SecretsManager}

  setup do
    System.put_env("AWS_ACCESS_KEY_ID", "AKIDTEST")
    System.put_env("AWS_SECRET_ACCESS_KEY", "secret")
    System.put_env("AWS_SESSION_TOKEN", "tok")
    System.put_env("AWS_REGION", "eu-central-1")

    on_exit(fn ->
      for v <- ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION),
          do: System.delete_env(v)
    end)

    :ok
  end

  defp fake(responder) do
    {:ok, pid} = FakeAWS.start_link(responder)
    {pid, [endpoint: FakeAWS.endpoint(pid)]}
  end

  describe "S3" do
    test "put/get/head/delete use path-style URLs with the endpoint and carry metadata" do
      {pid, opts} =
        fake(fn
          %{method: "PUT"} ->
            {200, [{"ETag", ~s("abc")}], ""}

          %{method: "GET", path: "/b/dir/f x.json"} ->
            {200, [{"Content-Type", "application/json"}], ~s({"a":1})}

          %{method: "HEAD"} ->
            {200,
             [
               {"Content-Length", "7"},
               {"Content-Type", "application/json"},
               {"ETag", ~s("abc")},
               {"x-amz-meta-owner", "ada"}
             ], ""}

          %{method: "DELETE"} ->
            {204, [], ""}
        end)

      assert {:ok, %{etag: ~s("abc")}} =
               S3.put_object(
                 "b",
                 "dir/f x.json",
                 ~s({"a":1}),
                 opts ++ [content_type: "application/json", metadata: %{owner: "ada"}]
               )

      put = FakeAWS.last(pid)
      assert put.raw_path == "/b/dir/f%20x.json" and put.path == "/b/dir/f x.json"

      assert put.headers["content-type"] == "application/json" and
               put.headers["x-amz-meta-owner"] == "ada"

      assert put.headers["x-amz-content-sha256"] ==
               :crypto.hash(:sha256, ~s({"a":1})) |> Base.encode16(case: :lower)

      assert put.headers["x-amz-security-token"] == "tok"

      assert {:ok, ~s({"a":1}), headers} = S3.get_object("b", "dir/f x.json", opts)
      assert {"content-type", "application/json"} in headers

      assert {:ok, %{size: 7, etag: ~s("abc"), metadata: %{"owner" => "ada"}}} =
               S3.head_object("b", "k", opts)

      assert :ok = S3.delete_object("b", "k", opts)
    end

    test "keys with spaces, plus, unicode and reserved characters sign correctly (FakeAWS verifies)" do
      {pid, opts} =
        fake(fn
          %{method: "PUT"} -> {200, [{"ETag", ~s("e")}], ""}
          %{method: "GET"} -> {200, [], "body"}
        end)

      for key <- [
            "dir/a b.txt",
            "plus+sign.csv",
            "umlaut/ärger ß.json",
            "paren(1)=x,y;z@!*'.bin",
            "a//b"
          ] do
        assert {:ok, _} = S3.put_object("b", key, "x", opts), key
        assert {:ok, "body", _} = S3.get_object("b", key, opts), key
      end

      assert FakeAWS.last(pid).path == "/b/a//b"
      assert Enum.any?(FakeAWS.requests(pid), &(&1.raw_path == "/b/dir/a%20b.txt"))
      assert Enum.any?(FakeAWS.requests(pid), &(&1.raw_path == "/b/plus%2Bsign.csv"))
    end

    test "errors are parsed from S3 XML and 404 on HEAD is NotFound" do
      {_pid, opts} =
        fake(fn
          %{method: "HEAD"} ->
            {404, [], ""}

          _ ->
            {403, [],
             ~s(<?xml version="1.0"?><Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>)}
        end)

      assert {:error, {"NotFound", _}} = S3.head_object("b", "missing", opts)
      assert {:error, {"AccessDenied", "Access Denied"}} = S3.get_object("b", "k", opts)
    end

    test "list_objects parses ListObjectsV2 XML and passes prefix" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?><ListBucketResult><Name>b</Name><Prefix>r/</Prefix><IsTruncated>true</IsTruncated><NextContinuationToken>tok1</NextContinuationToken>
      <Contents><Key>r/a.json</Key><LastModified>2026-10-09T00:00:00.000Z</LastModified><ETag>&quot;e1&quot;</ETag><Size>12</Size></Contents>
      <Contents><Key>r/b.json</Key><LastModified>2026-10-09T00:00:01.000Z</LastModified><ETag>&quot;e2&quot;</ETag><Size>3</Size></Contents></ListBucketResult>
      """

      {pid, opts} = fake(fn _ -> {200, [], xml} end)

      assert {:ok, [%{key: "r/a.json", size: 12, etag: ~s("e1")}, %{key: "r/b.json", size: 3}],
              %{truncated?: true, next_token: "tok1"}} =
               S3.list_objects("b", opts ++ [prefix: "r/", max_keys: 2])

      assert FakeAWS.last(pid).query == %{"list-type" => "2", "max-keys" => "2", "prefix" => "r/"}
    end

    test "presign produces a query-signed URL with the documented fields" do
      url =
        S3.presign(:get, "my-bucket", "dir/a b.txt",
          expires_in: 300,
          now: ~U[2026-10-09 12:00:00Z]
        )

      uri = URI.parse(url)

      assert uri.host == "my-bucket.s3.eu-central-1.amazonaws.com" and
               uri.path == "/dir/a%20b.txt"

      q = URI.decode_query(uri.query)
      assert q["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256"
      assert q["X-Amz-Credential"] == "AKIDTEST/20261009/eu-central-1/s3/aws4_request"
      assert q["X-Amz-Date"] == "20261009T120000Z" and q["X-Amz-Expires"] == "300"
      assert q["X-Amz-SignedHeaders"] == "host" and q["X-Amz-Security-Token"] == "tok"
      assert String.length(q["X-Amz-Signature"]) == 64
      # deterministic for the same inputs
      assert url ==
               S3.presign(:get, "my-bucket", "dir/a b.txt",
                 expires_in: 300,
                 now: ~U[2026-10-09 12:00:00Z]
               )

      put =
        S3.presign(:put, "my-bucket", "k",
          content_type: "text/plain",
          now: ~U[2026-10-09 12:00:00Z]
        )

      assert URI.decode_query(URI.parse(put).query)["X-Amz-SignedHeaders"] == "content-type;host"
    end
  end

  describe "SQS" do
    test "send/receive/delete speak the JSON protocol" do
      {pid, opts} =
        fake(fn
          %{headers: %{"x-amz-target" => "AmazonSQS.SendMessage"}} ->
            {200, [], ~s({"MessageId":"m1","MD5OfMessageBody":"x"})}

          %{headers: %{"x-amz-target" => "AmazonSQS.ReceiveMessage"}} ->
            {200, [],
             ~s({"Messages":[{"MessageId":"m1","ReceiptHandle":"rh","Body":"{\\"order\\":1}","Attributes":{"ApproximateReceiveCount":"1"},"MessageAttributes":{"k":{"DataType":"String","StringValue":"v"}}}]})}

          %{headers: %{"x-amz-target" => "AmazonSQS.DeleteMessage"}} ->
            {200, [], ""}

          %{headers: %{"x-amz-target" => "AmazonSQS.ChangeMessageVisibility"}} ->
            {200, [], ""}
        end)

      q = "https://sqs.eu-central-1.amazonaws.com/123/q"

      assert {:ok, %{message_id: "m1"}} =
               SQS.send_message(
                 q,
                 %{"order" => 1},
                 opts ++ [attributes: %{k: "v"}, delay_seconds: 5]
               )

      sent = FakeAWS.last(pid)
      assert sent.headers["content-type"] == "application/x-amz-json-1.0"
      body = JSON.decode!(sent.body)
      assert body["MessageBody"] == ~s({"order":1}) and body["DelaySeconds"] == 5

      assert body["MessageAttributes"] == %{
               "k" => %{"DataType" => "String", "StringValue" => "v"}
             }

      assert {:ok,
              [
                %{
                  message_id: "m1",
                  receipt_handle: "rh",
                  body: ~s({"order":1}),
                  message_attributes: %{"k" => "v"}
                }
              ]} = SQS.receive_messages(q, opts ++ [max: 5, wait_seconds: 2])

      assert JSON.decode!(FakeAWS.last(pid).body)["MaxNumberOfMessages"] == 5
      assert :ok = SQS.delete_message(q, "rh", opts)
      assert :ok = SQS.change_visibility(q, "rh", 30, opts)
    end

    test "JSON errors are surfaced with their type" do
      {_pid, opts} =
        fake(fn _ ->
          {400, [],
           ~s({"__type":"com.amazonaws.sqs#QueueDoesNotExist","message":"The specified queue does not exist."})}
        end)

      assert {:error, {"QueueDoesNotExist", "The specified queue does not exist."}} =
               SQS.send_message("https://sqs.eu-central-1.amazonaws.com/1/none", "x", opts)
    end
  end

  test "SNS publish form-encodes and parses the XML response" do
    {pid, opts} =
      fake(fn _ ->
        {200, [],
         ~s(<PublishResponse><PublishResult><MessageId>mid-1</MessageId></PublishResult></PublishResponse>)}
      end)

    assert {:ok, %{message_id: "mid-1", sequence_number: nil}} =
             SNS.publish(
               "arn:aws:sns:eu-central-1:1:t",
               %{"e" => 1},
               opts ++ [subject: "s", attributes: %{"type" => "order"}]
             )

    req = FakeAWS.last(pid)
    form = URI.decode_query(req.body)
    assert form["Action"] == "Publish" and form["TopicArn"] == "arn:aws:sns:eu-central-1:1:t"
    assert form["Message"] == ~s({"e":1}) and form["Subject"] == "s"

    assert form["MessageAttributes.entry.1.Name"] == "type" and
             form["MessageAttributes.entry.1.Value.StringValue"] == "order"

    assert req.headers["content-type"] =~ "x-www-form-urlencoded"
  end

  test "SSM get_parameter, get_parameters and paginated by_path" do
    {pid, opts} =
      fake(fn
        %{headers: %{"x-amz-target" => "AmazonSSM.GetParameter"}} ->
          {200, [], ~s({"Parameter":{"Name":"/a","Value":"v","Type":"SecureString","Version":3}})}

        %{headers: %{"x-amz-target" => "AmazonSSM.GetParameters"}} ->
          {200, [], ~s({"Parameters":[{"Name":"/a","Value":"1"}],"InvalidParameters":["/zz"]})}

        %{body: body, headers: %{"x-amz-target" => "AmazonSSM.GetParametersByPath"}} ->
          if JSON.decode!(body)["NextToken"],
            do: {200, [], ~s({"Parameters":[{"Name":"/app/prod/b","Value":"2"}]})},
            else:
              {200, [], ~s({"Parameters":[{"Name":"/app/prod/a","Value":"1"}],"NextToken":"n2"})}
      end)

    assert {:ok, "v"} = SSM.get_parameter("/a", opts)
    assert JSON.decode!(FakeAWS.last(pid).body) == %{"Name" => "/a", "WithDecryption" => true}
    assert {:ok, %{"/a" => "1"}, ["/zz"]} = SSM.get_parameters(["/a", "/zz"], opts)

    assert {:ok, %{"a" => "1", "b" => "2"}} =
             SSM.get_parameters_by_path("/app/prod/", opts ++ [strip_prefix: true])

    assert %{"/app/prod/a" => "1"} =
             SSM.get_parameters_by_path!("/app/prod/", opts) |> Map.take(["/app/prod/a"])

    {_pid, bad} = fake(fn _ -> {400, [], ~s({"__type":"ParameterNotFound","message":""})} end)
    assert {:error, {"ParameterNotFound", _}} = SSM.get_parameter("/nope", bad)
  end

  test "Secrets Manager string, binary and JSON secrets" do
    {_pid, opts} =
      fake(fn %{body: body} ->
        case JSON.decode!(body)["SecretId"] do
          "s" ->
            {200, [], ~s({"SecretString":"hunter2"})}

          "b" ->
            {200, [], ~s({"SecretBinary":"#{Base.encode64(<<1, 2>>)}"})}

          "j" ->
            {200, [], ~s({"SecretString":"{\\"user\\":\\"ada\\"}"})}

          _ ->
            {400, [],
             ~s({"__type":"ResourceNotFoundException","message":"Secrets Manager can't find the specified secret."})}
        end
      end)

    assert {:ok, "hunter2"} = SecretsManager.get_secret_value("s", opts)
    assert {:ok, <<1, 2>>} = SecretsManager.get_secret_value("b", opts)
    assert {:ok, %{"user" => "ada"}} = SecretsManager.get_secret_json("j", opts)
    assert {:error, {"InvalidJSON", _}} = SecretsManager.get_secret_json("s", opts)

    assert {:error, {"ResourceNotFoundException", _}} =
             SecretsManager.get_secret_value("missing", opts)
  end
end
