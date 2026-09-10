#!/usr/bin/env bash
set -euo pipefail

probe() {
  local mode=$1 label=$2 expected=$3 status
  set +e
  mix run --no-start --no-compile .github/scripts/dialyzer_probe.exs "$mode" "$label" \
    2>&1 | tee "dialyzer-probe-results/$label.log"
  status=${PIPESTATUS[0]}
  set -e
  if [[ "$status" != "$expected" ]]; then
    echo "Expected $label exit $expected; received $status" >&2
    exit 1
  fi
}

pair() {
  local label=$1 expected=$2
  probe classic "$label-classic" "$expected"
  probe incremental "$label-incremental" "$expected"
  if ! elixir .github/scripts/dialyzer_probe_compare.exs "$label-classic" "$label-incremental"; then
    touch dialyzer-probe-results/raw-parity-mismatch
  fi
  elixir .github/scripts/dialyzer_probe_deltas.exs "$label-classic" "$label-incremental"
}

cat > lib/ci_probe_marker.ex <<'EOF'
defmodule Logflare.CIProbe.TypeError do
  @spec value() :: integer()
  def value, do: :diagnostic_error
end
EOF
mix compile
pair error 2
probe incremental repeated-error-incremental 2
elixir .github/scripts/dialyzer_probe_compare.exs error-incremental repeated-error-incremental

python3 - <<'PY'
from pathlib import Path
p = Path('lib/ci_probe_marker.ex')
p.write_text(p.read_text().replace(':diagnostic_error', '0'))
PY
mix compile
pair fixed-error 0

rm lib/ci_probe_marker.ex
mix compile
probe incremental deleted-module-incremental 0
elixir .github/scripts/dialyzer_probe_compare.exs baseline-incremental deleted-module-incremental

git diff --exit-code -- lib .dialyzer_ignore.exs
