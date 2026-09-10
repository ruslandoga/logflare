#!/usr/bin/env bash
set -euo pipefail

mkdir -p dialyzer-probe-results
cp dialyzer-probe-reference/baseline-incremental.* dialyzer-probe-results/
for source in dialyzer-probe-reference/error-incremental.*; do
  cp "$source" "dialyzer-probe-results/prior-${source##*/}"
done

probe() {
  local label=$1 expected=$2 status
  set +e
  mix run --no-start --no-compile .github/scripts/dialyzer_probe.exs incremental "$label" \
    2>&1 | tee "dialyzer-probe-results/$label.log"
  status=${PIPESTATUS[0]}
  set -e
  if [[ "$status" != "$expected" ]]; then
    echo "Expected $label exit $expected; received $status" >&2
    exit 1
  fi
}

test -s dialyzer-incremental/logflare.iplt
cat > lib/ci_probe_marker.ex <<'EOF'
defmodule Logflare.CIProbe.TypeError do
  @spec value() :: integer()
  def value, do: :diagnostic_error
end
EOF
mix compile
probe resumed-error-incremental 2
elixir .github/scripts/dialyzer_probe_compare.exs prior-error-incremental resumed-error-incremental
probe repeated-error-incremental 2
elixir .github/scripts/dialyzer_probe_compare.exs resumed-error-incremental repeated-error-incremental

python3 - <<'PY'
from pathlib import Path
p = Path('lib/ci_probe_marker.ex')
p.write_text(p.read_text().replace(':diagnostic_error', '0'))
PY
mix compile
probe fixed-error-incremental 0
elixir .github/scripts/dialyzer_probe_fixed.exs

rm lib/ci_probe_marker.ex
mix compile
probe deleted-module-incremental 0
elixir .github/scripts/dialyzer_probe_compare.exs baseline-incremental deleted-module-incremental
git diff --exit-code -- lib .dialyzer_ignore.exs
