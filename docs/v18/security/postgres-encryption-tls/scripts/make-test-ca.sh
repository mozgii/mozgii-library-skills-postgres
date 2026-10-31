#!/usr/bin/env bash
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 MOZGII, Inc. (https://mozgii.com/)
# Make a private test CA, a PostgreSQL server certificate and one client certificate with OpenSSL 3 or later.
# For test and staging only; production certificates come from your organization's CA or a managed PKI.
# Usage: make-test-ca.sh OUT_DIR SERVER_DNS_NAME CLIENT_ROLE
#   example: make-test-ca.sh ./tls db1.acme.internal app_api
set -euo pipefail

usage='Usage: make-test-ca.sh OUT_DIR SERVER_DNS_NAME CLIENT_ROLE'
case "${1:-}" in
  -h|--help) echo "$usage"; exit 0 ;;
  '') echo "$usage" >&2; exit 2 ;;
esac

out=$1
server_name=${2:?server DNS name}
client_role=${3:?client role name (becomes the certificate CN)}

mkdir -p "$out"
cd "$out"
umask 077

# 1. Root CA: EC P-256 key, 10 years, marked as a CA.
openssl req -x509 -new -noenc -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
  -subj "/CN=Test Postgres Root CA" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -keyout ca.key -out ca.crt

# 2. Server certificate: the names clients use go in subjectAltName; verify-full checks them.
openssl req -new -noenc -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -subj "/CN=${server_name}" \
  -addext "subjectAltName=DNS:${server_name},DNS:localhost,IP:127.0.0.1" \
  -keyout server.key -out server.csr
printf 'extendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature\n' > server.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 397 \
  -copy_extensions copy -extfile server.ext -out server.crt

# 3. Client certificate: CN must equal the database role (or match a pg_ident.conf map).
openssl req -new -noenc -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -subj "/CN=${client_role}" \
  -keyout "${client_role}.key" -out "${client_role}.csr"
printf 'extendedKeyUsage=clientAuth\nkeyUsage=critical,digitalSignature\n' > client.ext
openssl x509 -req -in "${client_role}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -days 90 \
  -extfile client.ext -out "${client_role}.crt"

chmod 600 ./*.key
rm -f ./*.csr ./*.ext
openssl verify -CAfile ca.crt server.crt "${client_role}.crt"
echo "Made in $PWD; the server's OS user must own server.key."
echo "postgresql.conf needs server.crt, server.key and ca.crt as ssl_cert_file, ssl_key_file and ssl_ca_file."
echo "Client: sslmode=verify-full sslrootcert=ca.crt sslcert=${client_role}.crt sslkey=${client_role}.key"
