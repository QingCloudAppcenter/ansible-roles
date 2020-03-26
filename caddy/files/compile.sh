#!/usr/bin/env bash

set -eu

# From https://github.com/wmark/http.upload/issues/38#issuecomment-529623377

cat > go.mod << MOD_EOF
module caddy

go 1.13

require (
  blitznote.com/src/http.upload/v${CADDY_UPLOAD_VERSION%%.*} v$CADDY_UPLOAD_VERSION
  github.com/caddyserver/caddy v$CADDY_VERSION
)
MOD_EOF

cat > main.go << EOF
package main

import (
  "github.com/caddyserver/caddy/caddy/caddymain"

  _ "blitznote.com/src/http.upload/v${CADDY_UPLOAD_VERSION%%.*}"
)

func main() {
  caddymain.Run()
}
EOF

gofmt -w main.go
go mod tidy
go build -tags "caddyserver0.9 caddyserver1.0" -o $TARGET_FILE
