#!/bin/bash

# Execute the bounded-helper script from BoundedHelper.qml for real, and check
# the verdict it reports for each way a run can end.
#
# The verdict is the whole point of the wrapper: the panel publishes a reading
# only when the run exited 0, so anything that should not be published has to
# come back non-zero. A truncated weather line that reported success would be
# rendered as though it were the whole answer.

set -uo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

failures=0

report() {
  if [[ $1 == 0 ]]; then
    echo "PASS   : bounded::$2"
  else
    echo "FAIL!  : bounded::$2 -- $3"
    failures=$((failures + 1))
  fi
}

# Recover the script text from the JavaScript string concatenation in
# BoundedHelper.qml: the quoted fragments of the `command:` binding, with the
# // comments between them dropped and the overflow code substituted in.
python3 - "$PROJECT_DIR/BoundedHelper.qml" "$WORK/bounded.sh" <<'PY'
import ast, re, sys

src = open(sys.argv[1]).read()

overflow = re.search(r'readonly property int overflowExit:\s*(\d+)', src)
if not overflow:
    raise SystemExit("bounded.sh: could not find overflowExit")

body = src.split('"/bin/bash", "-c",', 1)[1].split('"omadeck-helper"', 1)[0]

parts = []
for line in body.split("\n"):
    line = line.strip()
    if line.startswith("//") or not line:
        continue
    if line.startswith("+"):
        line = line[1:].strip()
    # The exit code is interpolated between the single-quoted fragments, so
    # it has to be substituted in the same quoting the extractor reads.
    line = line.replace("root.overflowExit", "'%s'" % overflow.group(1))
    for lit in re.findall(r"'((?:[^'\\]|\\.)*)'", line):
        parts.append(ast.literal_eval('"%s"' % lit.replace('"', '\\"')))

script = "".join(parts)
if "head -c" not in script:
    raise SystemExit("bounded.sh: recovered script does not look right:\n" + script)
open(sys.argv[2], "w").write(script)
PY

if [[ ! -s $WORK/bounded.sh ]]; then
  echo "FAIL!  : bounded::extract -- could not recover the script from BoundedHelper.qml"
  exit 1
fi

printf '#!/bin/bash\nprintf "Fremont \xc2\xb7 Temp 76\xc2\xb0F"\n' > "$WORK/ok"
printf '#!/bin/bash\nyes AAAA\n' > "$WORK/flood"
printf '#!/bin/bash\nsleep 30\n' > "$WORK/hang"
printf '#!/bin/bash\nprintf partial\nexit 3\n' > "$WORK/failafter"
chmod +x "$WORK/ok" "$WORK/flood" "$WORK/hang" "$WORK/failafter"

run() { # helper, cap -> prints "rc bytes"
  local out rc
  out=$(/usr/bin/timeout --kill-after=2 2 /bin/bash -c "$(cat "$WORK/bounded.sh")" omadeck-helper "$1" "$2" 2>/dev/null)
  rc=$?
  echo "$rc ${#out}"
}

read -r rc bytes <<<"$(run "$WORK/ok" 256)"
[[ $rc == 0 && $bytes -gt 0 ]] && report 0 "publishes_a_clean_run" || report 1 "publishes_a_clean_run" "rc=$rc bytes=$bytes"

# Over the ceiling: the producer is cut off at the source and the run is
# refused whole rather than published truncated.
read -r rc bytes <<<"$(run "$WORK/flood" 256)"
[[ $rc == 9 ]] && report 0 "refuses_an_overflowing_producer" || report 1 "refuses_an_overflowing_producer" "expected 9, got $rc"

# Past the deadline: timeout's 124. This is the case the old wrapper published.
read -r rc bytes <<<"$(run "$WORK/hang" 256)"
[[ $rc == 124 ]] && report 0 "refuses_a_run_past_its_deadline" || report 1 "refuses_a_run_past_its_deadline" "expected 124, got $rc"

# A producer that gave up halfway: pipefail carries its status out past wc, so
# the half-answer is refused rather than published.
read -r rc bytes <<<"$(run "$WORK/failafter" 256)"
[[ $rc == 3 ]] && report 0 "refuses_a_producer_that_failed_midway" || report 1 "refuses_a_producer_that_failed_midway" "expected 3, got $rc"

# A helper that is not there at all.
read -r rc bytes <<<"$(run "$WORK/nothing-here" 256)"
[[ $rc == 127 ]] && report 0 "refuses_a_missing_executable" || report 1 "refuses_a_missing_executable" "expected 127, got $rc"

if ((failures == 0)); then
  echo "Totals: 5 passed, 0 failed (bounded.sh)"
else
  echo "Totals: $((5 - failures)) passed, $failures failed (bounded.sh)"
fi
exit $((failures > 0))
