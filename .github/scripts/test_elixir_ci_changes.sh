#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
classifier="$script_dir/elixir_ci_changes.sh"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
test_count=0

prepare_repo() {
  test_count=$((test_count + 1))
  test_repo="$test_root/repo-$test_count"
  git init --quiet "$test_repo"
  git -C "$test_repo" config user.email ci-test@example.invalid
  git -C "$test_repo" config user.name "CI filter test"
  git -C "$test_repo" config commit.gpgsign false
  git -C "$test_repo" config core.hooksPath /dev/null
  mkdir -p "$test_repo/lib" "$test_repo/test/logflare"
  printf 'original source\n' > "$test_repo/lib/example.ex"
  printf 'original test\n' > "$test_repo/test/logflare/example_test.exs"
  git -C "$test_repo" add .
  git -C "$test_repo" commit --quiet -m 'Base fixtures'
  base_sha=$(git -C "$test_repo" rev-parse HEAD)
  head_sha=$base_sha
  event_name=pull_request
}

commit_changes() {
  git -C "$test_repo" add -A
  git -C "$test_repo" commit --quiet -m 'Changed fixtures'
  head_sha=$(git -C "$test_repo" rev-parse HEAD)
}

assert_checks() {
  local label=$1 enabled=$2 key value
  local expected="$test_root/expected" actual="$test_root/actual"
  : > "$expected"
  : > "$actual"

  for key in backend frontend quality rust static; do
    value=false
    case " $enabled " in
      *" $key "*) value=true ;;
    esac
    printf '%s=%s\n' "$key" "$value" >> "$expected"
  done

  if ! (
    cd "$test_repo"
    EVENT_NAME="$event_name" BASE_SHA="$base_sha" HEAD_SHA="$head_sha" \
      GITHUB_OUTPUT="$actual" bash "$classifier"
  ) > "$test_root/run.log" 2>&1; then
    printf 'FAIL: %s (classifier exited unsuccessfully)\n' "$label" >&2
    cat "$test_root/run.log" >&2
    exit 1
  fi

  if ! diff -u "$expected" "$actual"; then
    printf 'FAIL: %s\n' "$label" >&2
    cat "$test_root/run.log" >&2
    exit 1
  fi

  printf 'PASS: %s\n' "$label"
}

assert_changed_paths() {
  local label=$1 enabled=$2 path
  shift 2
  prepare_repo
  for path in "$@"; do
    mkdir -p "$(dirname "$test_repo/$path")"
    printf 'changed\n' >> "$test_repo/$path"
  done
  commit_changes
  assert_checks "$label" "$enabled"
}

assert_changed_paths 'ordinary test modified' 'backend quality' test/logflare/example_test.exs
assert_changed_paths 'ordinary test added' 'backend quality' test/logflare/new_test.exs
assert_changed_paths 'top-level ordinary test' 'backend quality' test/new_test.exs
assert_changed_paths 'multiple ordinary tests' 'backend quality' test/one_test.exs test/nested/two_test.exs
assert_changed_paths 'ordinary test with spaces' 'backend quality' 'test/a space/example_test.exs'
assert_changed_paths 'ordinary test with newline' 'backend quality' $'test/a\nnewline/example_test.exs'

prepare_repo
rm "$test_repo/test/logflare/example_test.exs"
commit_changes
assert_checks 'ordinary test deleted' 'backend quality'

prepare_repo
git -C "$test_repo" mv lib/example.ex test/renamed_test.exs
commit_changes
assert_checks 'compiled source renamed into ordinary test' 'backend quality static'

prepare_repo
git -C "$test_repo" mv test/logflare/example_test.exs test/renamed_test.exs
commit_changes
assert_checks 'ordinary test renamed' 'backend quality'

while IFS='|' read -r label path; do
  assert_changed_paths "$label" 'backend quality static' "$path"
done <<'CASES'
compiled source|lib/example.ex
compiled template|lib/logflare_web/templates/example.html.heex
test support|test/support/data_case.ex
test support ending in _test.exs|test/support/nested/example_test.exs
test helper|test/test_helper.exs
test fixture|test/fixtures/example.json
unknown test file|test/logflare/example.exs
configuration|config/test.exs
in-app documentation|docs/docs.logflare.com/docs/example.md
private compile-time resource|priv/generators/teams.txt
native SQL parser|native/sqlparser_ex/src/lib.rs
native lockfile|native/sqlparser_ex/Cargo.lock
Mix configuration|mix.exs
Mix dependencies|mix.lock
formatting configuration|.formatter.exs
lint configuration|.credo.exs
Dialyzer suppressions|.dialyzer_ignore.exs
version input|VERSION
base Dockerfile|Dockerfile.base
runner Dockerfile|Dockerfile.runner
multi-step Dockerfile|Dockerfile.multi-step
CI classifier script|.github/scripts/elixir_ci_changes.sh
CASES

while IFS='|' read -r label path; do
  assert_changed_paths "$label" 'backend quality rust static' "$path"
done <<'CASES'
tool versions|.tool-versions
root Cargo configuration|Cargo.toml
root Cargo lockfile|Cargo.lock
mapper source|native/mapper_ex/src/lib.rs
CASES

assert_changed_paths 'mixed ordinary test and source' 'backend quality static' test/new_test.exs lib/example.ex
assert_changed_paths 'ordinary test and frontend' 'backend frontend quality' test/new_test.exs assets/js/example.js
assert_changed_paths 'frontend only' 'frontend' assets/js/example.js
assert_changed_paths 'frontend lockfile' 'frontend' assets/package-lock.json
assert_changed_paths 'feature test only' 'quality' test/e2e/features/example_test.exs
assert_changed_paths 'excluded e2e test' '' test/e2e/example_test.exs
assert_changed_paths 'excluded Supabase test' '' test/e2e/supabase/example_test.exs
assert_changed_paths 'unrelated documentation' '' README.md
assert_changed_paths 'workflow edit' 'backend frontend quality rust static' .github/workflows/elixir-ci.yml

prepare_repo
assert_checks 'empty diff' ''
event_name=workflow_dispatch
base_sha=missing
head_sha=missing
assert_checks 'manual dispatch without valid commits' 'backend frontend quality rust static'
event_name=push
base_sha=0000000000000000000000000000000000000000
head_sha=$(git -C "$test_repo" rev-parse HEAD)
assert_checks 'push without a previous commit' 'backend frontend quality rust static'
event_name=pull_request
base_sha=missing
head_sha=$(git -C "$test_repo" rev-parse HEAD)
assert_checks 'missing base commit' 'backend frontend quality rust static'
base_sha=$head_sha
head_sha=missing
assert_checks 'missing head commit' 'backend frontend quality rust static'
base_sha=''
head_sha=''
assert_checks 'missing commit inputs' 'backend frontend quality rust static'

prepare_repo
printf 'changed\n' >> "$test_repo/test/logflare/example_test.exs"
commit_changes
event_name=push
assert_checks 'ordinary test changed on push' 'backend quality'

prepare_repo
git -C "$test_repo" checkout --quiet --orphan unrelated
git -C "$test_repo" commit --quiet -m 'Unrelated history'
head_sha=$(git -C "$test_repo" rev-parse HEAD)
assert_checks 'diff failure with valid but unrelated commits' 'backend frontend quality rust static'

printf 'All CI change classifier checks passed.\n'
