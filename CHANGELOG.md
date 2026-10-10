# Changelog

## [0.2.0] - 2026-10-10

### Fixed
- S3 signatures no longer double-encode the object key (`SignatureDoesNotMatch`
  for keys with spaces, `+`, `=`, unicode, …); the test server now verifies every
  signature the way AWS does. Presigned URLs keep a non-default port in the host.
- `Mayfly.Idempotency`: completion and release are conditioned on a per-claim
  token, so a stale owner can neither overwrite nor delete a claim that was taken
  over; the result store is retried on transient errors and warns above DynamoDB's
  item size.
- `Mayfly.AWS.SQS.receive_messages/2` HTTP timeout outlasts the long poll.
- `Mayfly.AWS.DynamoDB.to_av/1` raises on unsupported terms instead of storing
  `inspect/1` output; floats are formatted without exponent.
- `mayfly` is a Hex dependency by default (`MAYFLY_PATH` for local development).

### Added
- `Mayfly.AWS.S3`: put/get/head/delete object, ListObjectsV2 (one page), presigned
  GET/PUT URLs (query-string SigV4).
- `Mayfly.AWS.SQS`: send_message, receive_messages, delete_message, change_visibility
  (JSON protocol).
- `Mayfly.AWS.SNS`: publish with subject, attributes, FIFO fields.
- `Mayfly.AWS.SSM`: get_parameter, get_parameters, get_parameters_by_path(!) with
  pagination and decryption.
- `Mayfly.AWS.SecretsManager`: get_secret_value (string or binary), get_secret_json.
- `Mayfly.AWS.HTTP.request/5` (any method, response headers) and a shared
  `Mayfly.AWS.Request` sign-and-send with JSON/XML error parsing.
- `Mayfly.AWS.FakeAWS` test server (test/support).

All verified from a Lambda function against the real services in one invocation.

## [0.1.0] - 2026-10-09

### Added
- `Mayfly.Idempotency.run/3`: DynamoDB-backed exactly-once execution with
  claim / complete / replay / in-progress / release semantics and takeover of
  expired claims.
- `Mayfly.AWS.DynamoDB`: PutItem, GetItem, UpdateItem, DeleteItem and raw
  `request/3` over DynamoDB JSON 1.0 with plain-map attribute conversion.
- `Mayfly.AWS.SigV4`: header-based Signature V4 (validated against the AWS
  SigV4 test suite), `Mayfly.AWS.Credentials` from the Lambda environment,
  `Mayfly.AWS.HTTP` lazy `:inets`/`:ssl` transport.
- `Mayfly.AWS.FakeDynamoDB` test server (test/support).
