#!/usr/bin/env bash
# Kept for CI and muscle memory: the AZ-loss test now lives with the other failure tests.
exec "$(dirname "$0")/../infra/failure-tests/f1-az-loss.sh" "$@"
