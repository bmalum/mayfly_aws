defmodule Mayfly.AWS.SigV4Test do
  use ExUnit.Case, async: true

  alias Mayfly.AWS.{Credentials, SigV4}

  # Credentials and timestamp from the AWS SigV4 test suite
  # (https://docs.aws.amazon.com/IAM/latest/UserGuide/signature-v4-test-suite.html).
  @creds %Credentials{
    access_key_id: "AKIDEXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    region: "us-east-1"
  }
  @ts ~U[2015-08-30 12:36:00Z]

  defp authorization(headers), do: headers |> List.keyfind("authorization", 0) |> elem(1)

  defp signature(headers),
    do: headers |> authorization() |> String.split("Signature=") |> List.last()

  test "signing key derivation (AWS documented example)" do
    key =
      SigV4.signing_key(
        "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        "20150830",
        "us-east-1",
        "iam"
      )

    assert Base.encode16(key, case: :lower) ==
             "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9"
  end

  # Published signatures from the AWS SigV4 test suite (aws-sig-v4-test-suite).
  test "get-vanilla" do
    headers =
      SigV4.sign(
        @creds,
        "service",
        "us-east-1",
        "GET",
        "https://example.amazonaws.com/",
        [],
        "",
        @ts,
        content_sha256: false
      )

    assert {"host", "example.amazonaws.com"} in headers
    assert {"x-amz-date", "20150830T123600Z"} in headers

    assert authorization(headers) =~
             "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date"

    assert signature(headers) ==
             "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
  end

  test "get-vanilla-query-order-key-case (query canonicalisation)" do
    url = "https://example.amazonaws.com/?Param2=value2&Param1=value1"

    headers =
      SigV4.sign(@creds, "service", "us-east-1", "GET", url, [], "", @ts, content_sha256: false)

    assert signature(headers) ==
             "b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500"
  end

  test "post-vanilla-query" do
    url = "https://example.amazonaws.com/?Param1=value1"

    headers =
      SigV4.sign(@creds, "service", "us-east-1", "POST", url, [], "", @ts, content_sha256: false)

    assert signature(headers) ==
             "28038455d6de14eafc1f9222cf5aa6f1a96197d7deb8263271d420d138af7f11"
  end

  test "post-x-www-form-urlencoded (body hashing and extra signed header)" do
    headers =
      SigV4.sign(
        @creds,
        "service",
        "us-east-1",
        "POST",
        "https://example.amazonaws.com/",
        [{"Content-Type", "application/x-www-form-urlencoded"}],
        "Param1=value1",
        @ts,
        content_sha256: false
      )

    assert authorization(headers) =~ "SignedHeaders=content-type;host;x-amz-date"

    assert signature(headers) ==
             "ff11897932ad3f4e8b18135d722051e5ac45fc38421b1da7b9d196a0fe09473a"
  end

  test "session token is signed and present" do
    creds = %{@creds | session_token: "TOKEN"}

    headers =
      SigV4.sign(
        creds,
        "dynamodb",
        "eu-central-1",
        "POST",
        "https://dynamodb.eu-central-1.amazonaws.com/",
        [
          {"Content-Type", "application/x-amz-json-1.0"},
          {"X-Amz-Target", "DynamoDB_20120810.GetItem"}
        ],
        ~s({"TableName":"t"}),
        @ts
      )

    assert {"x-amz-security-token", "TOKEN"} in headers

    assert authorization(headers) =~
             "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date;x-amz-security-token;x-amz-target"

    # header names are lowercased, values trimmed
    assert {"content-type", "application/x-amz-json-1.0"} in headers
  end

  test "canonical helpers" do
    assert SigV4.canonical_path("/a b/c") == "/a%20b/c"
    assert SigV4.canonical_path(nil) == "/"
    assert SigV4.canonical_query("b=2&a=1&c") == "a=1&b=2&c="
    assert SigV4.canonical_query("k=a%20b") == "k=a%20b"
    assert SigV4.uri_encode("~-_.a1 /") == "~-_.a1%20%2F"
  end

  test "Credentials.from_env" do
    System.put_env("AWS_ACCESS_KEY_ID", "AKIA1")
    System.put_env("AWS_SECRET_ACCESS_KEY", "s3cret")
    System.put_env("AWS_SESSION_TOKEN", "tok")
    System.put_env("AWS_REGION", "eu-west-1")

    assert {:ok,
            %Credentials{
              access_key_id: "AKIA1",
              secret_access_key: "s3cret",
              session_token: "tok",
              region: "eu-west-1"
            }} = Credentials.from_env()

    System.delete_env("AWS_ACCESS_KEY_ID")
    assert {:error, :missing_credentials} = Credentials.from_env()
    assert_raise RuntimeError, ~r/not set/, fn -> Credentials.from_env!() end
  after
    for v <- ~w(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_REGION),
        do: System.delete_env(v)
  end
end
