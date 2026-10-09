# Changelog

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
