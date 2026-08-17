require "json"
require "minitest/autorun"
require_relative "../lib/customy/data"

class RecordingTransport
  attr_reader :calls

  def initialize(statuses = [202])
    @statuses = statuses
    @calls = []
  end

  def call(url, headers, body, timeout)
    payload = JSON.parse(body)
    @calls << { url: url, headers: headers, payload: payload, timeout: timeout }
    status = @statuses.empty? ? 202 : @statuses.shift
    count = payload.fetch("batch", [payload]).length
    response = status < 300 ? { accepted: count, deduplicated: 0, quarantined: 0, results: [] } : { error: "temporary" }
    [status, JSON.generate(response)]
  end
end

class CustomyDataClientTest < Minitest::Test
  def client(transport, **options)
    counter = 0
    Customy::Data::Client.new(
      collect_url: "https://data.customy.ai",
      write_key: "cdw_test",
      transport: transport,
      retry_base_seconds: 0,
      now: -> { Time.utc(2026, 8, 16) },
      id_factory: -> { counter += 1; "message_#{counter}" },
      **options
    )
  end

  def test_portable_six_call_conformance
    vectors = JSON.parse(File.read(File.expand_path("../../sdk-data/conformance/customer-data-v1.json", __dir__)))
    assert_equal Customy::Data::CONFORMANCE_CONTRACT, vectors["contract"]
    transport = RecordingTransport.new(Array.new(6, 202))
    sdk = client(transport)
    vectors["eventTypes"].each { |event| sdk.send_event(event) }
    assert_equal %w[track identify group page screen alias], transport.calls.map { |call| call[:payload]["type"] }
    transport.calls.each do |call|
      assert_equal "cdw_test", call[:headers]["x-write-key"]
      assert_equal "1.0", call[:payload]["schemaVersion"]
      vectors["forbiddenPayloadKeys"].each { |key| refute call[:payload].key?(key) }
    end
  end

  def test_retry_keeps_message_id
    transport = RecordingTransport.new([503, 429, 202])
    client(transport).track("Checkout Started", { value: 10 }, anonymous_id: "anon_1")
    assert_equal 3, transport.calls.length
    assert_equal ["message_1"], transport.calls.map { |call| call[:payload]["messageId"] }.uniq
  end

  def test_redaction_tenant_rejection_and_before_send
    transport = RecordingTransport.new
    sdk = client(
      transport,
      redact_fields: %w[password cardNumber],
      before_send: ->(event) { event.merge("traits" => { "password" => "reintroduced" }) }
    )
    sdk.identify({ password: "secret", payment: { cardNumber: "4111" } }, user_id: "user_1")
    assert_equal "[REDACTED]", transport.calls[0][:payload]["traits"]["password"]
    assert_raises(ArgumentError) do
      sdk.send_event("type" => "identify", "userId" => "u", "organizationId" => "forged")
    end
  end

  def test_batch_restores_queue_after_partial_failure
    sdk = client(RecordingTransport.new([202, 503]), max_batch_size: 2, max_retries: 0)
    %w[A B C].each { |name| sdk.enqueue("type" => "track", "event" => name, "anonymousId" => "anon_1") }
    assert_raises(Customy::Data::Error) { sdk.flush }
    assert_equal 4, sdk.enqueue("type" => "track", "event" => "D", "anonymousId" => "anon_1")
  end

  def test_before_send_can_block
    transport = RecordingTransport.new
    sdk = client(transport, before_send: ->(_event) { nil })
    assert_raises(Customy::Data::Error) do
      sdk.send_event("type" => "track", "event" => "Blocked", "anonymousId" => "anon_1")
    end
    assert_empty transport.calls
  end
end
