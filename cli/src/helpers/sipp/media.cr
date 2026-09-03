require "random/secure"

# RTP media generation for SIPp scenarios.
#
# Ported from sippy_cup (https://github.com/mojolingo/sippy_cup), MIT-licensed,
# Copyright (c) 2013 Mojo Lingo LLC. sippy_cup builds its packets with PacketFu;
# there is no such shard for Crystal, so the Ethernet/IPv4/UDP/RTP framing and
# the libpcap container are written out by hand here. The RTP payloads, packet
# counts and inter-packet timing follow sippy_cup's Media exactly, so a scenario
# compiled here plays the same as one compiled there.
#
# SIPp cannot synthesize audio: `play_pcap_audio` replays a capture file, which
# is why a DTMF test needs a pcap at all. Writing one is the whole reason
# sippy_cup exists.
module VoIPAppz::Sipp
  class Error < Exception; end

  class Media
    # Both payload types are packetized at 20ms, so one packet is one ptime and
    # `elapsed` below advances in lockstep with the media clock.
    PTIME = 20

    PCMU_PAYLOAD_ID = 0_u8
    PCMU_RATE       = 8         # kHz
    PCMU_SILENCE    = 0xff_u8   # µ-law silence
    PCMU_INTERVAL   = PCMU_RATE * PTIME

    DTMF_PAYLOAD_ID = 101_u8 # matches the a=rtpmap:101 offered in the INVITE
    DTMF_INTERVAL   = 160
    DTMF_DURATION   = 250 # ms per digit
    DTMF_VOLUME     = 10_u8
    END_OF_EVENT    = 0x80_u8

    # RFC 4733 event codes are the index into this table, so the order is the
    # wire format, not a preference.
    DIGITS = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "#", "A", "B", "C", "D"]

    PCAP_MAGIC        = 0xa1b2c3d4_u32
    PCAP_SNAPLEN      =     0xffff_u32
    LINKTYPE_ETHERNET =          1_u32

    # The addresses baked into the capture are placeholders: SIPp rewrites both
    # endpoints from the negotiated SDP when it replays the file. They only have
    # to be well-formed.
    def initialize(@from_addr : String = "127.0.0.255", @from_port : Int32 = 55555,
                   @to_addr : String = "127.255.255.255", @to_port : Int32 = 44444)
      @steps = [] of {Symbol, String}
    end

    def silence(milliseconds : Int32) : Nil
      @steps << {:silence, milliseconds.to_s}
    end

    def dtmf(digit : String) : Nil
      raise Error.new("invalid DTMF digit `#{digit}`") unless DIGITS.includes?(digit)
      @steps << {:dtmf, digit}
    end

    def empty? : Bool
      @steps.empty?
    end

    # `start_time` and `ssrc` are arguments rather than internals so the
    # compiler is a pure function of its inputs — the specs compare bytes.
    def compile(start_time : Int64 = Time.utc.to_unix,
                ssrc : UInt32 = Random::Secure.rand(0x8000_0000_u32)) : Bytes
      io = IO::Memory.new
      write_file_header io

      sequence = 0
      timestamp = 0
      elapsed = 0
      first_audio = true

      @steps.each do |(action, value)|
        case action
        when :silence
          (value.to_i // PTIME).times do
            # The marker bit flags the start of a talkspurt; only the very first
            # audio packet of the capture carries it.
            marker = first_audio ? 1_u8 : 0_u8
            first_audio = false
            timestamp += PCMU_INTERVAL
            elapsed += PTIME
            sequence += 1
            packet = rtp(marker, PCMU_PAYLOAD_ID, sequence, timestamp, ssrc,
              Bytes.new(PCMU_INTERVAL, PCMU_SILENCE))
            write_packet io, packet, start_time, elapsed
          end
        when :dtmf
          event = DIGITS.index(value).not_nil!.to_u8
          count = (DTMF_DURATION // PTIME) + 1
          count.times do |i|
            elapsed += PTIME
            sequence += 1
            last = i == count - 1
            marker = i.zero? ? 1_u8 : 0_u8
            # The timestamp deliberately does NOT advance within a digit: every
            # packet of one event carries the timestamp of the event's start,
            # and the duration field is what grows.
            packet = rtp(marker, DTMF_PAYLOAD_ID, sequence, timestamp, ssrc,
              dtmf_event(event, i, last))
            write_packet io, packet, start_time, elapsed

            next unless last
            # The end-of-event packet goes out three times. It is the only thing
            # telling the far end the key came back up, so losing it leaves a
            # digit held down for the rest of the call.
            2.times do
              sequence += 1
              packet = rtp(0_u8, DTMF_PAYLOAD_ID, sequence, timestamp, ssrc,
                dtmf_event(event, i, last))
              write_packet io, packet, start_time, elapsed
            end
          end
          timestamp += count * DTMF_INTERVAL
        end
      end

      io.to_slice
    end

    private def dtmf_event(event : UInt8, index : Int32, end_of_event : Bool) : Bytes
      flags = DTMF_VOLUME
      flags |= END_OF_EVENT if end_of_event
      payload = Bytes.new(4)
      payload[0] = event
      payload[1] = flags
      IO::ByteFormat::BigEndian.encode((DTMF_INTERVAL * (index + 1)).to_u16, payload[2, 2])
      payload
    end

    private def rtp(marker : UInt8, payload_id : UInt8, sequence : Int32,
                    timestamp : Int32, ssrc : UInt32, media : Bytes) : Bytes
      frame = Bytes.new(12 + media.size)
      frame[0] = 0x80_u8 # version 2, no padding, no extension, no CSRCs
      frame[1] = (marker << 7) | payload_id
      IO::ByteFormat::BigEndian.encode(sequence.to_u16!, frame[2, 2])
      IO::ByteFormat::BigEndian.encode(timestamp.to_u32!, frame[4, 4])
      IO::ByteFormat::BigEndian.encode(ssrc, frame[8, 4])
      media.copy_to(frame + 12)
      frame
    end

    private def write_file_header(io : IO) : Nil
      io.write_bytes PCAP_MAGIC, IO::ByteFormat::LittleEndian
      io.write_bytes 2_u16, IO::ByteFormat::LittleEndian # version major
      io.write_bytes 4_u16, IO::ByteFormat::LittleEndian # version minor
      io.write_bytes 0_i32, IO::ByteFormat::LittleEndian # GMT offset
      io.write_bytes 0_u32, IO::ByteFormat::LittleEndian # timestamp accuracy
      io.write_bytes PCAP_SNAPLEN, IO::ByteFormat::LittleEndian
      io.write_bytes LINKTYPE_ETHERNET, IO::ByteFormat::LittleEndian
    end

    private def write_packet(io : IO, payload : Bytes, start_time : Int64, elapsed : Int32) : Nil
      frame = ethernet_frame payload
      # SIPp paces the replay off these timestamps, so `elapsed` (ms of media
      # written so far) is what actually sets the packet rate on the wire.
      usec = elapsed.to_i64 * 1_000
      io.write_bytes (start_time + usec // 1_000_000).to_u32, IO::ByteFormat::LittleEndian
      io.write_bytes (usec % 1_000_000).to_u32, IO::ByteFormat::LittleEndian
      io.write_bytes frame.size.to_u32, IO::ByteFormat::LittleEndian # captured
      io.write_bytes frame.size.to_u32, IO::ByteFormat::LittleEndian # on the wire
      io.write frame
    end

    private def ethernet_frame(payload : Bytes) : Bytes
      udp_length = 8 + payload.size
      ip_length = 20 + udp_length
      frame = Bytes.new(14 + ip_length)

      # Ethernet. SIPp reads the EtherType to find the IP header and ignores the
      # addresses; a synthetic capture has no real MACs to give, so they stay
      # zero rather than being invented.
      frame[12] = 0x08_u8
      frame[13] = 0x00_u8

      ip = frame + 14
      ip[0] = 0x45_u8 # IPv4, 20-byte header
      IO::ByteFormat::BigEndian.encode(ip_length.to_u16, ip[2, 2])
      ip[8] = 32_u8 # TTL
      ip[9] = 17_u8 # UDP
      address(@from_addr).copy_to(ip + 12)
      address(@to_addr).copy_to(ip + 16)
      IO::ByteFormat::BigEndian.encode(header_checksum(ip[0, 20]), ip[10, 2])

      udp = ip + 20
      IO::ByteFormat::BigEndian.encode(@from_port.to_u16, udp[0, 2])
      IO::ByteFormat::BigEndian.encode(@to_port.to_u16, udp[2, 2])
      IO::ByteFormat::BigEndian.encode(udp_length.to_u16, udp[4, 2])
      # The UDP checksum stays zero: optional over IPv4 (RFC 768), and SIPp
      # reads the payload out of the frame without validating it.
      payload.copy_to(udp + 8)

      frame
    end

    private def address(value : String) : Bytes
      parts = value.split('.')
      raise Error.new("invalid IPv4 address `#{value}`") unless parts.size == 4
      Bytes.new(4) do |i|
        parts[i].to_u8? || raise Error.new("invalid IPv4 address `#{value}`")
      end
    end

    private def header_checksum(header : Bytes) : UInt16
      sum = 0_u32
      i = 0
      while i < header.size
        sum += (header[i].to_u32 << 8) | header[i + 1].to_u32
        i += 2
      end
      while sum > 0xffff
        sum = (sum & 0xffff) + (sum >> 16)
      end
      (~sum).to_u16!
    end
  end
end
