require "http/client"
require "json"
require "uri"
require "./env_file"
require "./project"

module VoIPAppz
  # The API and the mailbox it sends OTP mail through.
  #
  # WHY THE MAILBOX IS THE WITNESS: /auth/forget_password always answers 200 —
  # anything else would enumerate accounts — so the endpoint cannot tell you
  # whether the mail was sent and only the mailbox can. For months it was not:
  # every customer's SMTP provider was seeded with address="", Jobs::Mail::Send
  # dropped the code as `smtp_not_configured`, and the login screen just waited.
  # /health was green throughout.
  module Mailbox
    extend self

    @@dotenv : Hash(String, String)? = nil

    # Environment, then .env, then the default — the order every other CLI value
    # resolves in, and compose's own rule for ${VAR:-default}: empty never wins.
    def setting(key : String, fallback : String) : String
      return ENV[key].as(String) if ENV[key]?.presence
      @@dotenv ||= (VoIPAppz::EnvFile.load(File.join(VoIPAppz::Project.root, ".env"), first_wins: true) rescue {} of String => String)
      @@dotenv.not_nil![key]?.presence || fallback
    end

    def api : String
      ENV["API_URL"]?.presence || "http://127.0.0.1:#{setting("VA_API_PORT", "5000")}"
    end

    def mail : String
      ENV["MAILPIT_URL"]?.presence || "http://127.0.0.1:#{setting("VA_MAILPIT_PORT", "8025")}"
    end

    def get(url : String) : String?
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = 2.seconds
      client.read_timeout = 5.seconds
      if (auth = credentials(uri))
        client.basic_auth(*auth)
      end
      response = client.get(uri.request_target)
      response.success? ? response.body : nil
    rescue
      nil
    end

    # The mailbox UI is published, so it has a password (MP_UI_AUTH, which
    # covers its API too). Credentials in the URL win — HTTP::Client ignores
    # them on its own — then user `admin` with VA_MAILPIT_UI_PASSWORD, resolved
    # like every other setting. Mailbox reads only: the API gets none.
    def credentials(uri : URI) : {String, String}?
      if (user = uri.user.presence)
        return {URI.decode_www_form(user), URI.decode_www_form(uri.password || "")}
      end
      return nil unless uri.host == URI.parse(mail).host && uri.port == URI.parse(mail).port
      password = setting("VA_MAILPIT_UI_PASSWORD", "")
      password.empty? ? nil : {"admin", password}
    end

    # Form-encoded, the way the admin SPA sends it.
    def post(path : String, form : Hash(String, String)) : {Int32, String}
      response = HTTP::Client.post("#{api}#{path}",
        headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
        body: URI::Params.encode(form))
      {response.status_code, response.body}
    rescue ex
      {0, "#{api}#{path} did not answer (#{ex.message})"}
    end

    # Mailpit search, narrowed to one account and optionally one subject.
    def search(email : String, subject : String? = nil) : JSON::Any?
      q = subject ? "to:#{email} subject:\"#{subject}\"" : "to:#{email}"
      body = get("#{mail}/api/v1/search?query=#{URI.encode_path_segment(q)}&limit=1") || return nil
      JSON.parse(body) rescue nil
    end

    def count(email : String, subject : String? = nil) : Int32
      search(email, subject).try(&.["messages_count"]?.try(&.as_i?)) || 0
    end

    def newest(email : String, subject : String? = nil) : JSON::Any?
      search(email, subject).try(&.["messages"]?.try(&.as_a?)).try(&.first?)
    end
  end
end
