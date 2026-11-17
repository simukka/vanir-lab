#!/usr/bin/env bash
# Install pinned lab tooling into ~/.local/bin. Re-running is safe: tools at the
# right version are skipped.
set -euo pipefail

KIND_VERSION=v0.33.0
KUBECTL_VERSION=v1.37.0
HELM_VERSION=v4.3.1
KWOK_VERSION=v0.8.0

BIN="${HOME}/.local/bin"
mkdir -p "$BIN"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

have() { # have <cmd> <version-substring>
  command -v "$1" >/dev/null 2>&1 && "$1" version 2>/dev/null | grep -q -- "$2"
}

verify() { # verify <file> <expected-sha256>
  echo "$2  $1" | sha256sum -c --quiet -
}

if ! have kind "$KIND_VERSION"; then
  url="https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64"
  curl -fsSL -o "$TMP/kind" "$url"
  verify "$TMP/kind" "$(curl -fsSL "${url}.sha256sum" | awk '{print $1}')"
  install -m 0755 "$TMP/kind" "$BIN/kind"
fi

if ! have kubectl "$KUBECTL_VERSION"; then
  url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  curl -fsSL -o "$TMP/kubectl" "$url"
  verify "$TMP/kubectl" "$(curl -fsSL "${url}.sha256")"
  install -m 0755 "$TMP/kubectl" "$BIN/kubectl"
fi

if ! have helm "$HELM_VERSION"; then
  url="https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
  curl -fsSL -o "$TMP/helm.tgz" "$url"
  verify "$TMP/helm.tgz" "$(curl -fsSL "${url}.sha256sum" | awk '{print $1}')"
  tar -xzf "$TMP/helm.tgz" -C "$TMP" linux-amd64/helm
  install -m 0755 "$TMP/linux-amd64/helm" "$BIN/helm"
fi

# kwok publishes no checksums; the in-cluster controller is deployed from the
# release manifest, this CLI is only a convenience.
if ! have kwok "$KWOK_VERSION"; then
  curl -fsSL -o "$TMP/kwok" \
    "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_VERSION}/kwok-linux-amd64"
  install -m 0755 "$TMP/kwok" "$BIN/kwok"
fi

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "NOTE: add $BIN to PATH (e.g. in ~/.bashrc)" ;;
esac
echo "tools ready: kind $KIND_VERSION, kubectl $KUBECTL_VERSION, helm $HELM_VERSION, kwok $KWOK_VERSION"
