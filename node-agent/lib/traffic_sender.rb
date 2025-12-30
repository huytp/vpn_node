require 'httparty'
require 'json'
require_relative 'traffic_meter'

module VPNNode
  class TrafficSender
    def initialize(signer, backend_url, traffic_meter)
      @signer = signer
      @backend_url = backend_url
      @traffic_meter = traffic_meter
      @current_epoch_id = 1
    end

    # Lấy current epoch_id từ backend
    def get_current_epoch_id
      begin
        response = HTTParty.get(
          "#{@backend_url}/rewards/epochs",
          headers: { 'Content-Type' => 'application/json' },
          timeout: 5
        )

        if response.success?
          epochs = JSON.parse(response.body)
          # Lấy epoch mới nhất chưa committed hoặc epoch hiện tại
          current_epoch = epochs.find { |e| e['status'] == 'pending' || e['status'] == 'processing' }
          if current_epoch
            @current_epoch_id = current_epoch['epoch_id']
          elsif epochs.any?
            # Nếu không có pending/processing, lấy epoch mới nhất + 1
            latest_epoch_id = epochs.first['epoch_id']
            @current_epoch_id = latest_epoch_id + 1
          end
        end
      rescue => e
        puts "⚠️  Failed to get current epoch_id: #{e.message}, using default: #{@current_epoch_id}"
      end

      @current_epoch_id
    end

    # Gửi một traffic record lên backend
    def send_traffic_record(session_id, epoch_id = nil)
      begin
        record = @traffic_meter.create_traffic_record(session_id, epoch_id)

        # Bỏ qua nếu traffic_mb = 0
        if record[:traffic_mb].to_f == 0.0
          puts "⏭️  Skipping traffic record with 0 MB for session: #{session_id}"
          return nil
        end

        response = HTTParty.post(
          "#{@backend_url}/nodes/traffic",
          body: {
            node: @signer.address,
            session_id: record[:session_id],
            traffic_mb: record[:traffic_mb],
            epoch_id: record[:epoch_id],
            timestamp: record[:timestamp],
            signature: record[:signature]
          }.to_json,
          headers: {
            'Content-Type' => 'application/json',
            'X-Node-Address' => @signer.address
          }
        )

        if response.success?
          data = JSON.parse(response.body)
          puts "✅ Traffic record sent successfully"
          puts "   ID: #{data['id']}"
          puts "   Traffic: #{data['traffic_mb']} MB (delta)"
          puts "   Reward eligible: #{data['reward_eligible']}"
          puts "   AI scored: #{data['ai_scored']}"

          # Đánh dấu traffic đã gửi để tránh trùng lặp
          @traffic_meter.mark_traffic_sent(session_id)

          return data
        else
          puts "❌ Failed to send traffic record: #{response.code} - #{response.body}"
          return nil
        end
      rescue => e
        puts "Error sending traffic record: #{e.message}"
        puts e.backtrace.first(3)
        nil
      end
    end

    # Gửi nhiều traffic records cùng lúc
    def send_traffic_records_batch(session_ids, epoch_id = nil)
      records = []
      skipped_count = 0

      session_ids.each do |session_id|
        begin
          record = @traffic_meter.create_traffic_record(session_id, epoch_id)
          session_info = @traffic_meter.get_session_info(session_id)

          # Bỏ qua nếu delta traffic = 0 (đã gửi hết hoặc chưa có traffic mới)
          if record[:traffic_mb].to_f == 0.0
            skipped_count += 1
            # Debug: Log chi tiết để hiểu tại sao skip
            if session_info
              puts "   ⏭️  Session #{session_id[0..8]}...: delta=0MB, total=#{session_info[:total_mb].round(2)}MB, last_sent=#{session_info[:last_sent_mb].round(2)}MB"
            end
            next
          end

          # Log session được gửi
          if session_info
            puts "   ✅ Session #{session_id[0..8]}...: delta=#{record[:traffic_mb].round(2)}MB, total=#{session_info[:total_mb].round(2)}MB, last_sent=#{session_info[:last_sent_mb].round(2)}MB"
          end

          records << {
            node: @signer.address,
            session_id: record[:session_id],
            traffic_mb: record[:traffic_mb],
            epoch_id: record[:epoch_id],
            timestamp: record[:timestamp],
            signature: record[:signature]
          }
        rescue => e
          puts "Error creating traffic record for session #{session_id}: #{e.message}"
        end
      end

      if skipped_count > 0
        puts "⏭️  Skipped #{skipped_count} traffic record(s) with 0 MB delta (đã gửi hết hoặc chưa có traffic mới từ lần gửi trước)"
      end

      return nil if records.empty?

      begin
        response = HTTParty.post(
          "#{@backend_url}/nodes/traffic/batch",
          body: {
            node: @signer.address,
            records: records
          }.to_json,
          headers: {
            'Content-Type' => 'application/json',
            'X-Node-Address' => @signer.address
          }
        )

        if response.success?
          data = JSON.parse(response.body)
          puts "✅ Sent #{data['created']} traffic record(s) successfully"
          puts "   Failed: #{data['failed']}" if data['failed'] > 0

          # Đánh dấu traffic đã gửi cho tất cả session đã gửi thành công
          # Nếu có results, chỉ mark các session thành công
          # Nếu không có results nhưng created > 0, mark tất cả
          if data['results'] && data['results'].is_a?(Array)
            data['results'].each do |result|
              session_id = result['session_id'] || result[:session_id]
              if session_id
                @traffic_meter.mark_traffic_sent(session_id)
              end
            end
          elsif data['created'] && data['created'] > 0
            # Nếu không có results nhưng có created, mark tất cả session trong records
            records.each do |record|
              session_id = record[:session_id]
              @traffic_meter.mark_traffic_sent(session_id) if session_id
            end
          end

          return data
        else
          puts "❌ Failed to send traffic records batch: #{response.code} - #{response.body}"
          return nil
        end
      rescue => e
        puts "Error sending traffic records batch: #{e.message}"
        puts e.backtrace.first(3)
        nil
      end
    end

    # Gửi traffic record khi session kết thúc
    def send_on_session_end(session_id, epoch_id = nil)
      puts "📤 Sending traffic record for ended session: #{session_id}"
      epoch_id ||= get_current_epoch_id
      result = send_traffic_record(session_id, epoch_id)

      if result
        puts "✅ Traffic record sent for session #{session_id}"
        puts "   Reward eligible: #{result['reward_eligible']}"
      else
        puts "❌ Failed to send traffic record for session #{session_id}"
      end

      result
    end
  end
end

