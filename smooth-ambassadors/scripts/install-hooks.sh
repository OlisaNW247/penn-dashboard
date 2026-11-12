#!/bin/sh
# One-time setup after cloning: makes git run the secrets check before every commit.
set -e
cd "$(dirname "$0")/.."
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit
echo "pre-commit secrets check installed"
