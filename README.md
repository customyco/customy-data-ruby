# Customy Data SDK for Ruby

Dependency-free Ruby SDK for governed `track`, `identify`, `group`, `page`,
`screen` and `alias` collection into Customy Data.

```ruby
require "customy/data"

data = Customy::Data::Client.new(
  collect_url: "https://data.customy.ai",
  write_key: "cdw_your_source_write_key",
  redact_fields: %w[password cardNumber]
)

data.track("Product Viewed", { sku: "A-1" }, anonymous_id: "anon_123")
```

The source write key resolves organization, project and environment inside
Customy Data. Caller-controlled tenant fields are rejected. Customy Analytics
is a governed read-model consumer and is never the collection endpoint.
