module VoIPAppz::Hep
  # SIP URI / Message / Parser, vendored from /opt/src/hep-crystal
  # (sipcapture/heplify-server port). Kept in a single file because the
  # whole thing is tightly coupled and only used by the HEP decoder.
  module Sip
    # SIP URI parser. Handles sip:, sips:, tel: schemes.
    class URI
      property error : String? = nil
      property scheme : String = ""
      property raw : String = ""
      property user : String = ""
      property host : String = ""
      property port : String = ""
      property port_int : Int32 = 0
      property secure : Bool = false

      def initialize(@raw : String)
      end

      def self.parse(s : String) : URI
        u = URI.new(s)
        u.parse
        u
      end

      def parse
        parse_scheme
        return if @error
        parse_at
      end

      private def parse_scheme
        if @raw.size > 5 && @raw[0, 5] == "sips:"
          @raw = @raw[5..]
          @scheme = "sips"
          @secure = true
        elsif @raw.size > 4 && @raw[0, 4] == "sip:"
          @raw = @raw[4..]
          @scheme = "sip"
        elsif @raw.size > 4 && @raw[0, 4] == "tel:"
          @raw = @raw[4..]
          @scheme = "tel"
        end
      end

      private def parse_at
        at_pos = @raw.index('@')
        if at_pos
          parse_user(at_pos)
          parse_host(at_pos)
        elsif @scheme == "tel"
          parse_tel_user
        else
          parse_host(0)
        end
      end

      private def parse_user(at_pos : Int32)
        semi = @raw[0...at_pos].index(';')
        @user = semi ? @raw[0...semi] : @raw[0...at_pos]
      end

      private def parse_tel_user
        semi = @raw.index(';')
        @user = semi ? @raw[0...semi] : @raw
      end

      private def parse_host(at_pos : Int32)
        start = at_pos > 0 ? at_pos + 1 : 0
        if start >= @raw.size
          @error = "malformed host part inside URI: #{@raw}"
          return
        end
        rest = @raw[start..]
        semi = rest.index(';')
        host_part = semi ? rest[0...semi] : rest
        colon = host_part.index(':')
        if colon
          @host = host_part[0...colon]
          port_str = host_part[colon + 1..]
          @port = port_str
          @port_int = port_str.to_i rescue 0
        else
          @host = host_part
        end
      end
    end

    # Parsed SIP message.
    class Message
      property error : String? = nil
      property msg : String = ""
      property body : String = ""

      property call_id : String = ""
      property x_call_id : String = ""

      property from_user : String = ""
      property from_host : String = ""
      property from_tag : String = ""

      property to_user : String = ""
      property to_host : String = ""
      property to_tag : String = ""

      property contact_user : String = ""
      property contact_host : String = ""
      property contact_port : Int32 = 0

      property uri_host : String = ""
      property uri_raw : String = ""
      property uri_user : String = ""
      property first_method : String = ""
      property first_resp : String = ""
      property first_resp_text : String = ""

      property cseq_method : String = ""
      property cseq_val : String = ""
      property user_agent : String = ""
      property server : String = ""
      property auth_user : String = ""
      property auth_val : String = ""
      property content_type : String = ""
      property content_length : String = ""
      property max_forwards : String = ""
      property expires : String = ""

      property via_one : String = ""
      property via_one_branch : String = ""

      property p_asserted_id_val : String = ""
      property pai_user : String = ""
      property pai_host : String = ""
      property remote_party_id_val : String = ""
      property diversion_val : String = ""
      property reason_val : String = ""
      property rtp_stat_val : String = ""
      property privacy : String = ""

      property profile : String = "default"
    end

    # SIP message parser.
    module Parser
      def self.parse(str : String) : Message
        str = str.lstrip("\r\n")

        headers_end = str.index("\r\n\r\n")
        headers_end = str.rindex("\r\n") if headers_end.nil?

        msg = Message.new
        msg.msg = str

        if headers_end.nil? || headers_end < 0
          msg.error = "no SIP end-of-headers found"
          return msg
        end

        body_start = str.index("\r\n\r\n")
        if body_start && body_start + 4 < str.size
          msg.body = str[body_start + 4..]
        end

        parse_headers(msg, str, headers_end)
        msg
      end

      private def self.parse_headers(msg : Message, raw : String, eof : Int32)
        cur_pos = 0
        first_line = true

        while cur_pos < eof + 2 && eof + 2 <= raw.size
          crlf_pos = raw[cur_pos..eof + 1].index('\n')
          break unless crlf_pos && crlf_pos > 0

          end_pos = cur_pos + crlf_pos
          line = if end_pos > 0 && raw[end_pos - 1] == '\r'
                   raw[cur_pos...end_pos - 1]
                 else
                   raw[cur_pos...end_pos]
                 end

          line = line.strip

          if first_line
            parse_start_line(msg, line)
            first_line = false
          else
            add_header(msg, line)
          end

          return if msg.error
          cur_pos = end_pos + 1
        end
      end

      private def self.parse_start_line(msg : Message, line : String)
        return if line.size < 3

        if line[0, 3] == "SIP"
          parts = line.split(' ', 3)
          if parts.size < 2
            msg.error = "malformed response start line"
            return
          end
          msg.first_resp = parts[1]
          msg.first_resp_text = parts.size > 2 ? parts[2] : ""
        else
          parts = line.split(' ', 3)
          if parts.size != 3
            msg.error = "malformed request start line"
            return
          end
          msg.first_method = parts[0]
          uri = URI.parse(parts[1])
          unless uri.error
            msg.uri_host = uri.host
            msg.uri_raw = uri.raw
            msg.uri_user = uri.user
          end
        end
      end

      private def self.add_header(msg : Message, line : String)
        return if line.empty? || line == " "

        sp = line.index(':')
        return unless sp

        hdr = line[0...sp].strip
        hdrv = sp + 1 < line.size ? line[sp + 1..].strip : ""

        if hdr.size == 1
          case hdr
          when "I", "i" then msg.call_id = hdrv
          when "F", "f" then parse_from(msg, hdrv)
          when "T", "t" then parse_to(msg, hdrv)
          when "M", "m" then parse_contact(msg, hdrv)
          when "V", "v" then parse_via(msg, hdrv)
          when "C", "c" then msg.content_type = hdrv
          when "L", "l" then msg.content_length = hdrv
          end
        elsif hdr.size == 2
          parse_to(msg, hdrv)
        else
          case hdr.downcase
          when "via"            then parse_via(msg, hdrv)
          when "from"           then parse_from(msg, hdrv)
          when "call-id"        then msg.call_id = hdrv
          when "cseq"
            msg.cseq_val = hdrv
            parse_cseq(msg, hdrv)
          when "contact"        then parse_contact(msg, hdrv)
          when "user-agent"     then msg.user_agent = hdrv
          when "server"         then msg.server = hdrv
          when "content-type"   then msg.content_type = hdrv
          when "content-length" then msg.content_length = hdrv
          when "authorization", "proxy-authorization"
            parse_authorization(msg, hdrv)
          when "max-forwards"   then msg.max_forwards = hdrv
          when "p-asserted-identity"
            msg.p_asserted_id_val = hdrv
            parse_pai(msg, hdrv)
          when "remote-party-id" then msg.remote_party_id_val = hdrv
          when "diversion"       then msg.diversion_val = hdrv
          when "reason"          then msg.reason_val = hdrv
          when "privacy"         then msg.privacy = hdrv
          when "x-rtp-stat"      then msg.rtp_stat_val = hdrv
          when "expires"         then msg.expires = hdrv
          end
        end
      end

      private def self.parse_from(msg : Message, val : String)
        uri_str = extract_uri(val)
        uri = URI.parse(uri_str)
        unless uri.error
          msg.from_user = uri.user
          msg.from_host = uri.host
        end
        msg.from_tag = extract_param("tag=", val)
      end

      private def self.parse_to(msg : Message, val : String)
        uri_str = extract_uri(val)
        uri = URI.parse(uri_str)
        unless uri.error
          msg.to_user = uri.user
          msg.to_host = uri.host
        end
        msg.to_tag = extract_param("tag=", val)
      end

      private def self.parse_contact(msg : Message, val : String)
        uri_str = extract_uri(val)
        uri = URI.parse(uri_str)
        unless uri.error
          msg.contact_user = uri.user
          msg.contact_host = uri.host
          msg.contact_port = uri.port_int
        end
      end

      private def self.parse_cseq(msg : Message, val : String)
        return if val.size < 3
        sp = val.index(' ')
        return unless sp && sp > 0 && sp + 1 < val.size
        method = val[sp + 1..].strip
        msg.cseq_method = method
      end

      private def self.parse_via(msg : Message, val : String)
        return unless msg.via_one.empty?
        msg.via_one = val
        if (a = val.index("branch="))
          rest = val[a..]
          if (c = rest.index(';'))
            msg.via_one_branch = rest[7...c] if rest.size > 7
          elsif rest.size > 7
            msg.via_one_branch = rest[7..]
          end
        end
      end

      private def self.parse_authorization(msg : Message, val : String)
        msg.auth_val = val
        msg.auth_user = extract_param("username=\"", val).rstrip('"')
      end

      private def self.parse_pai(msg : Message, val : String)
        uri_str = extract_uri(val)
        uri = URI.parse(uri_str)
        unless uri.error
          msg.pai_user = uri.user if msg.pai_user.empty?
          msg.pai_host = uri.host if msg.pai_host.empty?
        end
      end

      private def self.extract_uri(val : String) : String
        left = val.index('<')
        right = val.index('>')
        if left && right && right > left
          val[left + 1...right]
        else
          val
        end
      end

      private def self.extract_param(param : String, data : String) : String
        pos = data.index(param)
        return "" unless pos
        start = pos + param.size
        rest = data[start..]
        end_pos = 0
        rest.each_char_with_index do |c, i|
          case c
          when ';', ',', ' ', '\r', '\n', '\t'
            return rest[0...i]
          when '"'
            return rest[0...i]
          end
          end_pos = i + 1
        end
        rest[0...end_pos]
      end
    end
  end
end
