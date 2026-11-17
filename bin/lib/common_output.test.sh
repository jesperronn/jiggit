#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source bin/lib/bash_test.sh

test_redirected_diagnostics_are_plain() {
  local output
  output="$(JIGGIT_COLOR_OUTPUT=always bash -c 'source bin/lib/common_output.sh; debug debug; ok ok; warn warn; error error' 2>&1)"
  if [[ "${output}" == *$'\033'* ]]; then
    printf '[FAIL] redirected diagnostics contain ANSI\n' >&2
    return 1
  fi
  printf '[PASS] redirected diagnostics are plain\n'
}

test_terminal_and_mixed_streams() {
  python3 - <<'PYTEST'
import os, platform, shlex, subprocess, tempfile

def run(command, env=None):
    base_env = dict(os.environ)
    base_env.pop('NO_COLOR', None)
    args = (['script', '-q', '/dev/null', 'bash', '-c', command] if platform.system() == 'Darwin'
            else ['script', '-q', '-c', 'bash -c ' + shlex.quote(command), '/dev/null'])
    return subprocess.run(args,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          env={**base_env, 'TERM': 'xterm', **(env or {})}).stdout

command = 'source bin/lib/common_output.sh; ok good; warn caution; error bad'
tty = run(command)
assert b'\x1b[32m' in tty and b'\x1b[33m' in tty and b'\x1b[31m' in tty, tty
for env in ({'NO_COLOR': ''}, {'TERM': 'dumb'}):
    assert b'\x1b' not in run(command, env)
with tempfile.TemporaryDirectory() as temp:
    for cmd in (command, 'bin/jiggit --bogus'):
        path = temp + '/err'
        run(cmd + ' 2>' + path)
        assert b'\x1b' not in open(path, 'rb').read()
    path = temp + '/out'
    run('bin/jiggit --help >' + path)
    assert b'\x1b' not in open(path, 'rb').read()
tty = run('bin/jiggit --help')
assert b'\x1b[1;36m' in tty and b'\x1b[1;32m' in tty, tty
print('[PASS] terminal colors and mixed redirects')
PYTEST
}

run_tests "$@"
