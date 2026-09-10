#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT must point to the job output file}"

backend=true
frontend=true
quality=true
rust=true
static=true

if [[ "${EVENT_NAME:-}" == "workflow_dispatch" ]]; then
  echo "workflow_dispatch: running all checks"
else
  changed_paths=$(mktemp)
  trap 'rm -f "$changed_paths"' EXIT

  if git cat-file -e "${BASE_SHA:-}^{commit}" 2>/dev/null \
    && git cat-file -e "${HEAD_SHA:-}^{commit}" 2>/dev/null \
    && git diff --no-renames --name-only -z "$BASE_SHA...$HEAD_SHA" > "$changed_paths"; then
    backend=false
    frontend=false
    quality=false
    rust=false
    static=false

    while IFS= read -r -d '' path; do
      case "$path" in
        .github/workflows/elixir-ci.yml)
          backend=true
          frontend=true
          rust=true
          static=true
          ;;
        assets/*)
          frontend=true
          ;;
        .tool-versions|Cargo.toml|Cargo.lock|native/mapper_ex/*)
          backend=true
          rust=true
          static=true
          ;;
        test/e2e/features/*)
          quality=true
          ;;
        test/e2e/*)
          ;;
        test/support/*)
          backend=true
          static=true
          ;;
        test/*_test.exs)
          backend=true
          ;;
        .github/scripts/*|config/*|docs/docs.logflare.com/docs/*|lib/*|native/*|priv/*|test/*|*.exs|*.lock|VERSION|Dockerfile.base|Dockerfile.runner|Dockerfile.multi-step)
          backend=true
          static=true
          ;;
      esac
    done < "$changed_paths"
  else
    echo "::warning::Unable to determine changed files; running all checks"
  fi
fi

if [[ "$backend" == "true" ]]; then
  quality=true
fi

{
  echo "backend=$backend"
  echo "frontend=$frontend"
  echo "quality=$quality"
  echo "rust=$rust"
  echo "static=$static"
} >> "$GITHUB_OUTPUT"
