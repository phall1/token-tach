#!/usr/bin/env ruby
# Generate an App Store Connect ES256 bearer token without third-party gems.
require "base64"
require "json"
require "openssl"

def b64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

key_id = ENV.fetch("APP_STORE_CONNECT_API_KEY_ID")
issuer_id = ENV.fetch("APP_STORE_CONNECT_API_ISSUER_ID")
key_path = ENV.fetch("APP_STORE_CONNECT_API_KEY_PATH")
now = Time.now.to_i
header = b64url({ alg: "ES256", kid: key_id, typ: "JWT" }.to_json)
claims = b64url({ iss: issuer_id, iat: now, exp: now + 10 * 60, aud: "appstoreconnect-v1" }.to_json)
message = "#{header}.#{claims}"
key = OpenSSL::PKey.read(File.read(key_path))
asn1 = OpenSSL::ASN1.decode(key.dsa_sign_asn1(OpenSSL::Digest::SHA256.digest(message)))
raw_signature = asn1.value.map { |part| part.value.to_s(2).rjust(32, "\0") }.join
puts "#{message}.#{b64url(raw_signature)}"
