#!/bin/sh
# Regenerate the TLS distribution test certificates in this directory.
#
#   ca.pem                 the test cluster's private CA
#   node.pem, node.key     a node certificate signed by ca.pem
#   rogue_ca.pem           an unrelated CA
#   rogue.pem, rogue.key   a node certificate signed by rogue_ca.pem
#
# TEST ONLY. The node keys are committed so the tests run anywhere; never
# use these files outside test/brazier/cluster/tls_dist_test.gleam. The CA
# keys are discarded, so nothing else can be signed by these CAs.
#
# The certificates name no real host: the test turns server name checking
# off (client_server_name_indication disable) because peers run on
# whatever host runs the tests. Production certificates must name the
# host, and production must keep name checking on (docs/CLUSTERING.md).
#
# Usage: sh test/fixtures/dist_tls/regenerate.sh
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
DAYS=3650
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/node.ext" <<'EXT'
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = DNS:brazier-test-node
EXT

cat > "$WORK/ca.ext" <<'EXT'
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EXT

# make_ca NAME SUBJECT -> $DIR/NAME.pem (key kept in $WORK only)
make_ca() {
  openssl ecparam -name prime256v1 -genkey -noout -out "$WORK/$1.key"
  openssl req -new -key "$WORK/$1.key" -subj "$2" -out "$WORK/$1.csr"
  openssl x509 -req -in "$WORK/$1.csr" -signkey "$WORK/$1.key" -days "$DAYS" \
    -extfile "$WORK/ca.ext" -sha256 -out "$DIR/$1.pem"
}

# make_node NAME CA SUBJECT -> $DIR/NAME.pem, $DIR/NAME.key
make_node() {
  openssl ecparam -name prime256v1 -genkey -noout -out "$WORK/$1.ec"
  openssl pkcs8 -topk8 -nocrypt -in "$WORK/$1.ec" -out "$DIR/$1.key"
  openssl req -new -key "$DIR/$1.key" -subj "$3" -out "$WORK/$1.csr"
  openssl x509 -req -in "$WORK/$1.csr" -CA "$DIR/$2.pem" -CAkey "$WORK/$2.key" \
    -CAcreateserial -CAserial "$WORK/$2.srl" -days "$DAYS" \
    -extfile "$WORK/node.ext" -sha256 -out "$DIR/$1.pem"
}

make_ca ca "/CN=Brazier dist test CA"
make_node node ca "/CN=brazier-test-node"
make_ca rogue_ca "/CN=Brazier dist rogue CA"
make_node rogue rogue_ca "/CN=brazier-test-rogue"

chmod 0644 "$DIR"/*.pem
chmod 0600 "$DIR"/*.key
openssl verify -CAfile "$DIR/ca.pem" "$DIR/node.pem"
openssl verify -CAfile "$DIR/rogue_ca.pem" "$DIR/rogue.pem"
echo "Regenerated certificates in $DIR (valid $DAYS days)"
