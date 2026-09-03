require "./sip"

module VoIPAppz::Hep
  # HEP chunk type IDs (matching sipcapture/heplify-server).
  VERSION_CHUNK    =  1_u16 # IP protocol family
  PROTOCOL_CHUNK   =  2_u16 # IP protocol ID
  IP4_SRC_IP_CHUNK =  3_u16
  IP4_DST_IP_CHUNK =  4_u16
  IP6_SRC_IP_CHUNK =  5_u16
  IP6_DST_IP_CHUNK =  6_u16
  SRC_PORT_CHUNK   =  7_u16
  DST_PORT_CHUNK   =  8_u16
  TSEC_CHUNK       =  9_u16
  TMSEC_CHUNK      = 10_u16
  PROTO_TYPE_CHUNK = 11_u16
  NODE_ID_CHUNK    = 12_u16
  NODE_PW_CHUNK    = 14_u16
  PAYLOAD_CHUNK    = 15_u16
  CID_CHUNK        = 17_u16
  VLAN_CHUNK       = 18_u16
  NODE_NAME_CHUNK  = 19_u16

  MIN_PACKET_LEN = 6
  MAX_PACKET_LEN = 65507

  class ParseError < Exception; end

  # Decoded HEP packet.
  class Message
    property version : UInt32 = 0_u32
    property protocol : UInt32 = 0_u32
    property src_ip : String = ""
    property dst_ip : String = ""
    property src_port : UInt32 = 0_u32
    property dst_port : UInt32 = 0_u32
    property tsec : UInt32 = 0_u32
    property tmsec : UInt32 = 0_u32
    property proto_type : UInt32 = 0_u32
    property node_id : UInt32 = 0_u32
    property node_pw : String = ""
    property payload : String = ""
    property cid : String = ""
    property vlan : UInt32 = 0_u32
    property node_name : String = ""
    property proto_string : String = ""
    property timestamp : Time = Time.utc
    property sip : Sip::Message? = nil
    property sid : String = ""
    property profile : String = "default"

    def compute_timestamp
      if @tsec == 0 && @tmsec == 0
        @timestamp = Time.utc
      else
        @timestamp = Time.unix(@tsec.to_i64) + Time::Span.new(nanoseconds: @tmsec.to_i64 * 1000)
      end
    end

    def set_proto_string
      @proto_string = case @proto_type
                      when   1 then "sip"
                      when   5 then "rtcp"
                      when  34 then "rtpagent"
                      when  35 then "rtcpxr"
                      when  38 then "horaclifix"
                      when  53 then "dns"
                      when 100 then "log"
                      else          @proto_type.to_s
                      end
    end
  end

  # HEP3/HEP2 packet decoder.
  module Decoder
    def self.decode(packet : Bytes) : Message
      if packet.size < MIN_PACKET_LEN
        raise ParseError.new("packet too short: #{packet.size} bytes, min #{MIN_PACKET_LEN}")
      end

      msg = Message.new

      if packet[0] == 0x48 && packet[1] == 0x45 && packet[2] == 0x50 && packet[3] == 0x33
        parse_hep3(msg, packet)
      elsif packet[0] == 0x01 || packet[0] == 0x02
        parse_hep2(msg, packet)
      else
        raise ParseError.new("unknown packet format (first byte 0x#{packet[0].to_s(16)})")
      end

      msg.compute_timestamp
      msg.set_proto_string
      normalize_payload(msg)

      if msg.proto_type == 1 && msg.payload.bytesize > 32
        parse_sip(msg)
      end

      msg.node_name = msg.node_id.to_s if msg.node_name.empty?
      msg
    end

    private def self.parse_hep3(msg : Message, packet : Bytes)
      length = IO::ByteFormat::BigEndian.decode(UInt16, packet[4, 2])
      if length.to_i != packet.size
        raise ParseError.new("HEP3 length mismatch: packet=#{packet.size} header=#{length}")
      end

      current_byte = 6_u16

      while current_byte < length
        chunk = packet[current_byte..]
        if chunk.size < 6
          raise ParseError.new("HEP3 chunk must be >= 6 bytes (got #{chunk.size})")
        end

        chunk_type = IO::ByteFormat::BigEndian.decode(UInt16, chunk[2, 2])
        chunk_length = IO::ByteFormat::BigEndian.decode(UInt16, chunk[4, 2])

        if chunk.size < chunk_length.to_i || chunk_length < 6
          raise ParseError.new("HEP3 chunk #{chunk_type}: data #{chunk.size} < length #{chunk_length}")
        end

        body = chunk[6, chunk_length.to_i - 6]

        case chunk_type
        when VERSION_CHUNK, PROTOCOL_CHUNK, PROTO_TYPE_CHUNK
          raise ParseError.new("HEP3 chunk #{chunk_type} should be 1 byte (got #{body.size})") unless body.size == 1
        when SRC_PORT_CHUNK, DST_PORT_CHUNK, VLAN_CHUNK
          raise ParseError.new("HEP3 chunk #{chunk_type} should be 2 bytes (got #{body.size})") unless body.size == 2
        when IP4_SRC_IP_CHUNK, IP4_DST_IP_CHUNK, TSEC_CHUNK, TMSEC_CHUNK, NODE_ID_CHUNK
          raise ParseError.new("HEP3 chunk #{chunk_type} should be 4 bytes (got #{body.size})") unless body.size == 4
        when IP6_SRC_IP_CHUNK, IP6_DST_IP_CHUNK
          raise ParseError.new("HEP3 chunk #{chunk_type} should be 16 bytes (got #{body.size})") unless body.size == 16
        end

        case chunk_type
        when VERSION_CHUNK    then msg.version = body[0].to_u32
        when PROTOCOL_CHUNK   then msg.protocol = body[0].to_u32
        when IP4_SRC_IP_CHUNK then msg.src_ip = "#{body[0]}.#{body[1]}.#{body[2]}.#{body[3]}"
        when IP4_DST_IP_CHUNK then msg.dst_ip = "#{body[0]}.#{body[1]}.#{body[2]}.#{body[3]}"
        when IP6_SRC_IP_CHUNK then msg.src_ip = format_ipv6(body)
        when IP6_DST_IP_CHUNK then msg.dst_ip = format_ipv6(body)
        when SRC_PORT_CHUNK   then msg.src_port = IO::ByteFormat::BigEndian.decode(UInt16, body).to_u32
        when DST_PORT_CHUNK   then msg.dst_port = IO::ByteFormat::BigEndian.decode(UInt16, body).to_u32
        when TSEC_CHUNK       then msg.tsec = IO::ByteFormat::BigEndian.decode(UInt32, body)
        when TMSEC_CHUNK      then msg.tmsec = IO::ByteFormat::BigEndian.decode(UInt32, body)
        when PROTO_TYPE_CHUNK then msg.proto_type = body[0].to_u32
        when NODE_ID_CHUNK    then msg.node_id = IO::ByteFormat::BigEndian.decode(UInt32, body)
        when NODE_PW_CHUNK    then msg.node_pw = String.new(body)
        when PAYLOAD_CHUNK    then msg.payload = String.new(body)
        when CID_CHUNK        then msg.cid = String.new(body)
        when VLAN_CHUNK       then msg.vlan = IO::ByteFormat::BigEndian.decode(UInt16, body).to_u32
        when NODE_NAME_CHUNK  then msg.node_name = String.new(body)
        end

        current_byte += chunk_length
      end
    end

    private def self.parse_hep2(msg : Message, packet : Bytes)
      msg.proto_string = "sip"
      msg.proto_type = 1_u32

      msg.version = packet[0].to_u32
      header_len = packet[1].to_i
      family = packet[2]
      msg.protocol = packet[3].to_u32
      msg.src_port = IO::ByteFormat::BigEndian.decode(UInt16, packet[4, 2]).to_u32
      msg.dst_port = IO::ByteFormat::BigEndian.decode(UInt16, packet[6, 2]).to_u32

      if family == 10
        raise ParseError.new("HEP2 IPv6 packet too short: #{packet.size}") if packet.size < 52
        msg.src_ip = format_ipv6(packet[8, 16])
        msg.dst_ip = format_ipv6(packet[24, 16])
        if msg.version == 2
          msg.tsec = IO::ByteFormat::BigEndian.decode(UInt32, packet[40, 4])
          msg.tmsec = IO::ByteFormat::BigEndian.decode(UInt32, packet[44, 4])
          msg.node_id = IO::ByteFormat::BigEndian.decode(UInt16, packet[48, 2]).to_u32
        end
        header_len = {header_len, 52}.max
      else
        raise ParseError.new("HEP2 IPv4 packet too short: #{packet.size}") if packet.size < 28
        msg.src_ip = "#{packet[8]}.#{packet[9]}.#{packet[10]}.#{packet[11]}"
        msg.dst_ip = "#{packet[12]}.#{packet[13]}.#{packet[14]}.#{packet[15]}"
        if msg.version == 2
          msg.tsec = IO::ByteFormat::BigEndian.decode(UInt32, packet[16, 4])
          msg.tmsec = IO::ByteFormat::BigEndian.decode(UInt32, packet[20, 4])
          msg.node_id = IO::ByteFormat::BigEndian.decode(UInt16, packet[24, 2]).to_u32
        end
        header_len = {header_len, 28}.max
      end

      if header_len < packet.size
        msg.payload = String.new(packet[header_len, packet.size - header_len])
      end
    end

    private def self.format_ipv6(bytes : Bytes) : String
      parts = (0...8).map do |i|
        IO::ByteFormat::BigEndian.decode(UInt16, bytes[i * 2, 2]).to_s(16)
      end
      parts.join(":")
    end

    private def self.normalize_payload(msg : Message)
      return if msg.payload.empty?
      msg.payload = msg.payload.scrub("")
    end

    private def self.parse_sip(msg : Message)
      sip = Sip::Parser.parse(msg.payload)
      return if sip.error
      return if sip.cseq_method.bytesize < 3
      return if sip.call_id.empty?

      sip.first_method = sip.first_resp if sip.first_method.empty?

      msg.profile = case sip.cseq_method
                    when "INVITE", "ACK", "BYE", "CANCEL", "UPDATE", "PRACK", "REFER", "INFO", "NOTIFY"
                      "call"
                    when "REGISTER"
                      "registration"
                    else
                      "default"
                    end

      msg.cid = sip.x_call_id.empty? ? sip.call_id : sip.x_call_id if msg.cid.empty?
      msg.sid = sip.call_id
      msg.sip = sip
    end
  end
end
