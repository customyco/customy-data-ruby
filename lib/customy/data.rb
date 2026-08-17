require "json"
require "net/http"
require "securerandom"
require "thread"
require "time"
require "uri"

module Customy
  module Data
    VERSION = "0.1.0"
    CONFORMANCE_CONTRACT = "customy.customer-data-sdk.conformance.v1"
    FORBIDDEN_TENANT_FIELDS = %w[tenantId organizationId projectId environmentId].freeze
    RETRYABLE_STATUSES = [429, 500, 502, 503, 504].freeze

    class Error < StandardError
      attr_reader :status_code, :response

      def initialize(message, status_code: nil, response: nil)
        super(message)
        @status_code = status_code
        @response = response
      end
    end

    class Client
      attr_reader :queue_size

      def initialize(collect_url:, write_key:, transport: nil, max_retries: 3,
                     retry_base_seconds: 0.25, timeout_seconds: 10,
                     max_batch_size: 100, max_queue_size: 10_000,
                     redact_fields: [], before_send: nil,
                     now: -> { Time.now.utc }, id_factory: -> { SecureRandom.uuid })
        raise ArgumentError, "collect_url and write_key are required" if collect_url.to_s.empty? || write_key.to_s.empty?

        @collect_url = collect_url.sub(%r{/+$}, "")
        @write_key = write_key
        @transport = transport || method(:default_transport)
        @max_retries = [max_retries.to_i, 0].max
        @retry_base_seconds = [retry_base_seconds.to_f, 0].max
        @timeout_seconds = [timeout_seconds.to_f, 0.1].max
        @max_batch_size = [[max_batch_size.to_i, 1].max, 1_000].min
        @max_queue_size = [max_queue_size.to_i, 1].max
        @redact_fields = redact_fields.map(&:to_s).to_h { |field| [field, true] }
        @before_send = before_send
        @now = now
        @id_factory = id_factory
        @queue = []
        @queue_mutex = Mutex.new
        @flush_mutex = Mutex.new
      end

      def event(input)
        normalized = deep_copy(input)
        reject_tenant_fields!(normalized)
        type = normalized["type"]
        unless %w[track identify group page screen alias].include?(type)
          raise ArgumentError, "type must be track, identify, group, page, screen or alias"
        end
        unless %w[userId anonymousId groupId].any? { |key| present?(normalized[key]) }
          raise ArgumentError, "at least one userId, anonymousId or groupId is required"
        end
        raise ArgumentError, "track calls require an event name" if type == "track" && !present?(normalized["event"])

        normalized["messageId"] ||= @id_factory.call
        normalized["timestamp"] ||= @now.call.utc.iso8601(3)
        normalized["schemaVersion"] ||= "1.0"
        %w[properties traits consent].each { |key| normalized[key] ||= {} }
        normalized["context"] ||= {}
        normalized["context"]["library"] = { "name" => "customy-data-ruby", "version" => VERSION }
        redact!(normalized)
        if @before_send
          candidate = @before_send.call(deep_copy(normalized))
          raise Error, "event blocked by before_send" if candidate.nil?
          normalized = deep_copy(candidate)
          reject_tenant_fields!(normalized)
          redact!(normalized)
        end
        normalized
      end

      def send_event(input)
        request("event", event(input))
      end

      def track(name, properties = {}, **identity)
        send_event(identity_event("track", identity).merge("event" => name, "properties" => properties))
      end

      def identify(traits = {}, **identity)
        send_event(identity_event("identify", identity).merge("traits" => traits))
      end

      def group(traits = {}, **identity)
        send_event(identity_event("group", identity).merge("traits" => traits))
      end

      def page(properties = {}, **identity)
        send_event(identity_event("page", identity).merge("properties" => properties))
      end

      def screen(properties = {}, **identity)
        send_event(identity_event("screen", identity).merge("properties" => properties))
      end

      def alias(user_id, previous_id, **identity)
        send_event(identity_event("alias", identity).merge(
          "userId" => user_id,
          "anonymousId" => previous_id,
          "properties" => { "previousId" => previous_id }
        ))
      end

      def enqueue(input)
        normalized = event(input)
        @queue_mutex.synchronize do
          raise Error, "customer data queue is full" if @queue.length >= @max_queue_size
          @queue << normalized
          @queue.length
        end
      end

      def queue_size
        @queue_mutex.synchronize { @queue.length }
      end

      def flush
        @flush_mutex.synchronize do
          pending = @queue_mutex.synchronize do
            current = @queue
            @queue = []
            current
          end
          return empty_batch if pending.empty?

          aggregate = empty_batch
          begin
            pending.each_slice(@max_batch_size) do |batch|
              response = request("batch", { "batch" => batch })
              %w[accepted deduplicated quarantined].each do |key|
                aggregate[key] += response.fetch(key, 0).to_i
              end
              aggregate["results"].concat(response.fetch("results", []))
            end
          rescue StandardError
            @queue_mutex.synchronize { @queue = pending + @queue }
            raise
          end
          aggregate
        end
      end

      private

      def request(path, payload)
        body = JSON.generate(payload)
        headers = {
          "content-type" => "application/json",
          "user-agent" => "customy-data-ruby/#{VERSION}",
          "x-write-key" => @write_key
        }
        last_error = nil
        (@max_retries + 1).times do |attempt|
          begin
            status, response_body = @transport.call(
              "#{@collect_url}/v1/collect/#{path}", headers, body, @timeout_seconds
            )
            parsed = parse_json(response_body)
            unless status.between?(200, 299)
              raise Error.new("Customy Data collection failed with HTTP #{status}", status_code: status, response: parsed)
            end
            return parsed.is_a?(Hash) ? parsed : { "result" => parsed }
          rescue StandardError => error
            last_error = error
            raise unless attempt < @max_retries && retryable?(error)
            sleep(@retry_base_seconds * (2**attempt))
          end
        end
        raise last_error || Error.new("unknown collection failure")
      end

      def default_transport(url, headers, body, timeout)
        uri = URI(url)
        request = Net::HTTP::Post.new(uri, headers)
        request.body = body
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
                                   open_timeout: timeout, read_timeout: timeout) { |http| http.request(request) }
        [response.code.to_i, response.body.to_s]
      end

      def identity_event(type, identity)
        aliases = { user_id: "userId", anonymous_id: "anonymousId", group_id: "groupId" }
        identity.each_with_object({ "type" => type }) do |(key, value), result|
          result[aliases.fetch(key, key.to_s)] = value unless value.nil?
        end
      end

      def reject_tenant_fields!(value)
        found = FORBIDDEN_TENANT_FIELDS.select { |key| value.key?(key) }
        return if found.empty?
        raise ArgumentError, "tenant scope is derived from the write key; forbidden fields: #{found.sort.join(', ')}"
      end

      def redact!(value)
        case value
        when Hash
          value.each { |key, item| @redact_fields[key.to_s] ? value[key] = "[REDACTED]" : redact!(item) }
        when Array
          value.each { |item| redact!(item) }
        end
        value
      end

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end

      def parse_json(value)
        return {} if value.to_s.empty?
        JSON.parse(value)
      rescue JSON::ParserError
        { "raw" => value.to_s }
      end

      def retryable?(error)
        !error.is_a?(Error) || RETRYABLE_STATUSES.include?(error.status_code)
      end

      def present?(value)
        !value.nil? && value != ""
      end

      def empty_batch
        { "accepted" => 0, "deduplicated" => 0, "quarantined" => 0, "results" => [] }
      end
    end
  end
end
