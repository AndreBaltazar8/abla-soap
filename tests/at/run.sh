#!/usr/bin/env bash
# Clients generated from AT's published WSDLs, against a local mutual-TLS server that opens the token with openssl. Never calls
# AT. Needs python3 and openssl.
set -euo pipefail
compiler=${1:-ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
work=$root/build/at
mkdir -p "$work" build/gen
tools/fetch-wsdls.sh

mk=build/wsdl2abla
[[ -x $mk ]] || "$compiler" build tools/wsdl2abla.ab -o "$mk"
for pair in series:AtSeries transporte:AtTransporte fatcore:AtFatcore vies:Vies; do
    name=${pair%:*}
    [[ -f .wsdls/$name.wsdl ]] || continue
    "$mk" ".wsdls/$name.wsdl" --prefix "${pair#*:}" --import '"../../src/soap.ab"' -o "build/gen/at_$name.ab"
    printf 'import "at_%s.ab"\nfun main: int = 0\n' "$name" > "build/gen/check_$name.ab"
    "$compiler" build "build/gen/check_$name.ab" -o "build/gen/check_$name"
done

# Throwaway certificates: a CA, a server for localhost, a client under the CA, another client not under it, and AT's key.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/ca.key" -out "$work/ca.crt" -days 2 -subj /CN=abla-soap-ca 2>/dev/null
issue() { # name subject extensions
    openssl req -newkey rsa:2048 -nodes -keyout "$work/$1.key" -out "$work/$1.csr" -subj "/CN=$2" 2>/dev/null
    openssl x509 -req -in "$work/$1.csr" -CA "$work/ca.crt" -CAkey "$work/ca.key" -CAcreateserial -days 2 -out "$work/$1.crt" -extfile <(printf '%s\n' "$3") 2>/dev/null
}
issue server localhost 'subjectAltName=DNS:localhost'
issue client abla-soap-client 'extendedKeyUsage=clientAuth'
openssl pkcs12 -export -in "$work/client.crt" -inkey "$work/client.key" -out "$work/client.pfx" -passout pass:pfx-pass
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/at.key" -out "$work/at.crt" -days 2 -subj /CN=abla-soap-at 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/other.key" -out "$work/other.crt" -days 2 -subj /CN=abla-soap-stranger 2>/dev/null

"$compiler" build tests/at/client.ab -o "$work/client"
: > "$work/port"
python3 -I tests/at/mock_at.py "$work" "$work/port" &
server=$!
trap 'kill "$server" 2>/dev/null || true' EXIT
for _ in $(seq 100); do [[ -s $work/port ]] && break; sleep 0.1; done
[[ -s $work/port ]] || { echo "the mock server didn't start" >&2; exit 1; }
"$work/client" "$work" "$(cat "$work/port")"

# A program using the library without the subpath has no OpenSSL in it; the client above, which asked, does.
printf 'import "../src/soap.ab"\nimport "abla/http"\nfun main: int {\n    val c = soapClient(httpClient("h", { r: string, m: int, t: int -> HttpTransportResult("", false) }), "/", soap11, [atUsernameToken("a", "b", "c")], true)\n    var o = c.begin()\n    o.body()\n    if (c.send("a", o).ok()) 0 else 1\n}\n' > build/no_tls.ab
"$compiler" build build/no_tls.ab -o "$work/no_tls"
if ldd "$work/no_tls" | grep -qE 'libssl|libcrypto'; then echo 'OpenSSL got into a program without the tls subpath' >&2; exit 1; fi
ldd "$work/client" | grep -q libssl || { echo 'no OpenSSL in the client that asked for it?' >&2; exit 1; }
echo 'at: passed, and no OpenSSL without the subpath'
