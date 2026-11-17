#!/usr/bin/env bash
# Delete the whole lab cluster.
set -euo pipefail
kind delete cluster --name vanir
