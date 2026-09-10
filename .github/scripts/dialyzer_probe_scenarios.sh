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

python3 - <<'PY'
from pathlib import Path
p = Path('lib/logflare/utils/maybe.ex')
s = p.read_text()
before = 'def maybe_string_to_integer_or_zero(nil), do: 0'
assert s.count(before) == 1
p.write_text(s.replace(before, 'def maybe_string_to_integer_or_zero(nil), do: 1'))
PY
mix compile
pair leaf 0

git restore -- lib/logflare/utils/maybe.ex
python3 - <<'PY'
from pathlib import Path
p = Path('lib/logflare/user.ex')
s = p.read_text()
before = '@type id :: pos_integer()'
assert s.count(before) == 1
p.write_text(s.replace(before, '@type id :: non_neg_integer()'))
PY
mix compile
pair shared-type 0

git restore -- lib/logflare/user.ex
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
p = Path('.dialyzer_ignore.exs')
s = p.read_text()
assert s.startswith('[\n')
p.write_text(s.replace('[\n', '[\n  {"lib/ci_probe_marker.ex", :invalid_contract},\n', 1))
PY
pair ignored-error 0
elixir .github/scripts/dialyzer_probe_compare.exs error-incremental repeated-error-incremental

git restore -- .dialyzer_ignore.exs
python3 - <<'PY'
from pathlib import Path
p = Path('lib/ci_probe_marker.ex')
p.write_text(p.read_text().replace(':diagnostic_error', '0'))
PY
mix compile
pair fixed-error 0

rm lib/ci_probe_marker.ex
mix compile
pair deleted-module 0
elixir .github/scripts/dialyzer_probe_compare.exs baseline-incremental deleted-module-incremental

git diff --exit-code -- lib .dialyzer_ignore.exs
