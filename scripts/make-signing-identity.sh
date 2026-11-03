#!/bin/bash
# Creates a self-signed code-signing identity in a dedicated keychain so rebuilt
# copies of MultiAudio keep the same identity (and their macOS privacy permissions).
set -euo pipefail
D="$HOME/Library/Application Support/MultiAudioSigning"
KC="$D/signing.keychain-db"
if [[ -f "$KC" ]]; then echo "Already exists: $KC"; exit 0; fi
mkdir -p "$D"; cd "$D"
cat > cert.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = MultiAudio Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.cnf 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 -passout pass:multiaudio -name "MultiAudio Local Signing" 2>/dev/null
security create-keychain -p multiaudio "$KC"
security unlock-keychain -p multiaudio "$KC"
security set-keychain-settings "$KC"
security import id.p12 -k "$KC" -P multiaudio -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k multiaudio "$KC" >/dev/null
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KC"
rm -f key.pem id.p12
echo "Created signing identity in $KC"
