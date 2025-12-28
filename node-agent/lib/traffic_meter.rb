require 'json'
require 'thread'
require_relative 'signer'

module VPNNode
  class TrafficMeter
    class Session
      attr_accessor :id, :start_time, :bytes_in, :bytes_out, :last_update

      def initialize(id)
        @id = id
        @start_time = Time.now
        @bytes_in = 0
        @bytes_out = 0
        @last_update = Time.now
      end

      def total_bytes
        @bytes_in + @bytes_out
      end

      def total_mb
        total_bytes / (1024.0 * 1024.0)
      end
    end

    def initialize(signer)
      @sessions = {}
      @mutex = Mutex.new
      @signer = signer
      @epoch_id = 1
    end

    def start_session(session_id)
      @mutex.synchronize do
        @sessions[session_id] = Session.new(session_id)
      end
    end

    def update_session(session_id, bytes_in, bytes_out)
      @mutex.synchronize do
        session = @sessions[session_id]
        return unless session

        session.bytes_in += bytes_in
        session.bytes_out += bytes_out
        session.last_update = Time.now
      end
    end

    def end_session(session_id)
      @mutex.synchronize do
        @sessions.delete(session_id)
      end
    end

    def get_total_traffic
      @mutex.synchronize do
        total_bytes = @sessions.values.map(&:total_bytes).sum
        total_bytes / (1024.0 * 1024.0)
      end
    end

    def get_session_traffic(session_id)
      @mutex.synchronize do
        session = @sessions[session_id]
        return 0.0 unless session
        session.total_mb
      end
    end

    def get_active_sessions
      @mutex.synchronize do
        @sessions.keys.dup
      end
    end

    def create_traffic_record(session_id, epoch_id = @epoch_id)
      @mutex.synchronize do
        session = @sessions[session_id]
        raise "Session not found: #{session_id}" unless session

        record = {
          node: @signer.address,
          session_id: session_id,
          traffic_mb: session.total_mb,
          epoch_id: epoch_id,
          timestamp: Time.now.to_i
        }

        signature = @signer.sign_json(record)
        record[:signature] = signature

        record
      end
    end
  end
end

