#!/bin/sh
# Makes what the dev stack's TLS overlay (docker-compose.dev-tls.yml) needs to
# run Erlang distribution over TLS: a private CA, and for each host given a key,
# a certificate the CA signed and an `inet_tls_dist` option file.
#
#     dist_tls_certs.sh <host>...
#
# Writes into $DIST_TLS_DIR (default /dist_tls). What already exists is kept, so
# a restart neither rotates the CA nor breaks running links; a file that is
# missing, expires within 30 days, or was signed by an earlier CA is made again.
#
# Each certificate names its host as subject alternative name, because
# inet_tls_dist checks a peer against the host part of its node name, and is
# good for both client and server use, because every node is both. Both sides
# of a link check the other's certificate.
set -eu

dir=${DIST_TLS_DIR:-/dist_tls}
days=365
renew_within=$((30 * 24 * 3600))

[ "$#" -gt 0 ] || { echo "usage: $0 <host>..." >&2; exit 64; }
mkdir -p "$dir"
cd "$dir"
umask 077

fresh() {
  [ -s "$1" ] && openssl x509 -in "$1" -noout -checkend "$renew_within" >/dev/null 2>&1
}

if ! fresh ca.pem || [ ! -s ca.key ]; then
  openssl ecparam -name prime256v1 -genkey -noout -out ca.key
  openssl req -x509 -new -key ca.key -sha256 -days "$days" \
    -subj "/CN=flezha dev distribution CA" -out ca.pem
  echo "[dist-tls] made a new CA"
fi

for host in "$@"; do
  if fresh "$host.pem" && [ -s "$host.key" ] && [ -s "$host.conf" ] &&
    openssl verify -CAfile ca.pem "$host.pem" >/dev/null 2>&1; then
    echo "[dist-tls] kept $host"
    continue
  fi

  openssl ecparam -name prime256v1 -genkey -noout -out "$host.key"
  openssl req -new -key "$host.key" -subj "/CN=$host" -out "$host.csr"
  printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth,clientAuth\nkeyUsage=critical,digitalSignature\n' \
    "$host" >"$host.ext"
  openssl x509 -req -in "$host.csr" -CA ca.pem -CAkey ca.key -CAcreateserial \
    -days "$days" -sha256 -extfile "$host.ext" -out "$host.pem" 2>/dev/null
  rm -f "$host.csr" "$host.ext"

  cat >"$host.conf" <<EOF
[{server, [{certfile, "$dir/$host.pem"}, {keyfile, "$dir/$host.key"},
           {cacertfile, "$dir/ca.pem"}, {verify, verify_peer},
           {fail_if_no_peer_cert, true}, {secure_renegotiate, true}]},
 {client, [{certfile, "$dir/$host.pem"}, {keyfile, "$dir/$host.key"},
           {cacertfile, "$dir/ca.pem"}, {verify, verify_peer},
           {secure_renegotiate, true}]}].
EOF
  echo "[dist-tls] made $host"
done

# Both images run as uid 1000; run as root, this step hands the files to it.
if [ "$(id -u)" = 0 ]; then
  chown -R 1000:1000 "$dir"
fi
