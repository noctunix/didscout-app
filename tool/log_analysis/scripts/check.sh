#!/usr/bin/env bash
# Every check a change must pass, in this order.
set -euo pipefail

cd "$(dirname "$0")/.."

uv lock --check
uv run ruff format --check .
uv run ruff check .
uv run mypy
uv run pytest
