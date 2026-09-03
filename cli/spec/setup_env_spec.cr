require "./spec_helper"
require "../src/helpers/va_config"

# `setup` turns va.yaml into .env, and three of those values are load-bearing
# in ways that fail SILENTLY when they are wrong:
#
#   VA_VOIP_ADDRESS   points Gatus's probe at a machine. Wrong, and the probe
#                     watches a box nobody cares about and stays green.
#   ALERT_EMAIL_TO    blank makes Gatus drop its email provider at startup,
#                     once, and every alert afterwards goes nowhere.
#   VA_GATUS_*        the credential guarding a dashboard now bound to 0.0.0.0.
#
# None of the three raises anything when it is wrong, which is why they are
# pinned here rather than left to a live node to reveal.

private def env_from(yaml : String, secrets = {} of String => String)
  VoIPAppz::VaConfig.to_env(VoIPAppz::DeployConfig.from_yaml(yaml), secrets)
end

SETUP_COMBINED_YAML = <<-YAML
  organization:
    name: 'ExampleOrg'
    domain: 'pbx.example.com'
    email: 'ops@example.com'
  nodes:
    - uuid: 'aaaaaaaa-0000-0000-0000-000000000001'
      name: 'Node1'
      roles: [app, switch]
      profile:
        ip_address_external: '203.0.113.10'
        ip_address_internal: '10.0.0.5'
  YAML

SETUP_SPLIT_YAML = <<-YAML
  organization:
    name: 'ExampleOrg'
    domain: 'pbx.example.com'
    email: 'ops@example.com'
  nodes:
    - uuid: 'aaaaaaaa-0000-0000-0000-000000000001'
      name: 'App'
      roles: [app]
      profile:
        ip_address_external: '203.0.113.10'
        ip_address_internal: '10.0.0.5'
    - uuid: 'bbbbbbbb-0000-0000-0000-000000000002'
      name: 'Voip'
      roles: [switch]
      profile:
        ip_address_external: '203.0.113.20'
        ip_address_internal: '10.0.0.9'
  YAML

describe VoIPAppz::VaConfig do
  describe "VA_VOIP_ADDRESS" do
    # Gatus probes the voip node over the network from the app plane. On one
    # box that IS this address; the answer is correct, not a fallback.
    it "is this node's own address when both planes are one box" do
      env_from(SETUP_COMBINED_YAML)["VA_VOIP_ADDRESS"].should eq "10.0.0.5"
    end

    # The failure this prevents: leaving it at the app address on a split
    # deployment points the probe at the app node, which answers nothing on
    # :4000 — or worse, answers about the wrong machine.
    it "is the OTHER node's address when the switch role lives elsewhere" do
      env = env_from(SETUP_SPLIT_YAML)
      env["VA_VOIP_ADDRESS"].should eq "10.0.0.9"
      env["VA_APP_ADDRESS"].should eq "10.0.0.5"
    end
  end

  describe "alerting" do
    # Blank is what shipped before, and Gatus responds by ignoring the whole
    # email provider — one startup line, then permanent silence.
    it "sends alerts to the organization email collected at install" do
      env = env_from(SETUP_COMBINED_YAML)
      env["ALERT_EMAIL_TO"].should eq "ops@example.com"
      env["SMTP_FROM"].should eq "ops@example.com"
    end
  end

  # No gatus credential spec: there is no credential. Gatus is on the docker
  # network, reached by service name and by a loopback publish, so nothing is
  # exposed for one to protect. It had one for a single day; an empty value made
  # gatus refuse to start outright, which is how a node loses its alerting.
  describe "the gatus credential" do
    it "is not written at all" do
      env = env_from(SETUP_COMBINED_YAML, {"gatus_password" => "leftover-from-an-old-secrets-file"})
      env["VA_GATUS_PASSWORD"]?.should be_nil
      env["VA_GATUS_PASSWORD_BCRYPT_BASE64"]?.should be_nil
      env["VA_GATUS_USER"]?.should be_nil
    end
  end
end
