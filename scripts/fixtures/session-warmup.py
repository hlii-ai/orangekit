#!/usr/bin/env python3
"""POSIX lifecycle proof for the public SessionStart hook, including hook-group cancellation.
Windows process-group behavior requires the native Git Bash CI check; this is not a simulation of it.
"""
import json, os, pathlib, signal, subprocess, sys, tempfile, time, shutil

if os.name == "nt":
    print("skip POSIX lifecycle proof — run the native Git Bash cancellation check")
    sys.exit(0)

root = pathlib.Path(sys.argv[1]).resolve()
tmp = pathlib.Path(tempfile.mkdtemp(prefix='orangekit-warm-life-'))
realjq = shutil.which('jq')
realgit = shutil.which('git')
workers = []
try:
    for cancelled in (False, True):
        case = tmp / str(cancelled)
        case.mkdir()
        shim = case / 'shim'
        shim.mkdir()
        state = case / 'state'
        state.mkdir()
        transcript = case / 'transcript.jsonl'
        transcript.write_text('{"type":"user","message":"warm-up lifecycle"}\n')
        marker = case / 'index-pid'
        (shim / 'jq').write_text('#!/bin/bash\ncase " $* " in *" -nrR "*) echo $$ > "$TIW_MARKER"; sleep 60 ;; esac\nexec "$TIW_JQ" "$@"\n')
        (shim / 'git').write_text('#!/bin/bash\n[ "${TIW_CANCEL:-}" = 1 ] && sleep 60\nexec "$TIW_GIT" "$@"\n')
        for f in shim.iterdir():
            f.chmod(0o755)
        env = dict(os.environ, PATH=str(shim)+os.pathsep+os.environ['PATH'],
                   CLAUDE_PROJECT_DIR=str(case), CLAUDE_PLUGIN_ROOT=str(root), ORANGEKIT_STATE_DIR=str(state),
                   TIW_MARKER=str(marker), TIW_JQ=realjq, TIW_GIT=realgit, TIW_CANCEL=str(int(cancelled)))
        p = subprocess.Popen(['bash', str(root/'scripts/session-brief.sh')], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, start_new_session=True)
        workers.append(p)
        began = time.monotonic()
        payload = json.dumps(dict(cwd=str(case), session_id='life', transcript_path=str(transcript))).encode()
        p.stdin.write(payload)
        p.stdin.close()
        p.stdin = None
        while not marker.exists() and time.monotonic()-began < 6:
            time.sleep(.05)
        assert marker.exists(), 'warm worker never started'
        jqpid = int(marker.read_text())
        group = os.getpgid(jqpid)
        if cancelled:
            os.killpg(p.pid, signal.SIGKILL)
        out, err = p.communicate(timeout=5)
        assert time.monotonic()-began < 6, 'SessionStart held open by background descriptors'
        assert (p.returncode < 0) if cancelled else (p.returncode == 0), (p.returncode, err)
        assert not err, err
        assert group != p.pid, 'worker shares hook process group'
        print('PASS hook cancellation is isolated' if cancelled else 'PASS SessionStart returns while jq is stalled', flush=True)
        workers.append(group)
        while time.monotonic()-began < 24:
            try:
                os.killpg(group, 0)
            except ProcessLookupError:
                break
            time.sleep(.1)
        else:
            raise AssertionError('warm worker process group survived deadline')
        # The supervisor (its own group) removes the private file just after the worker group dies — give it up to 2 s
        settle = time.monotonic() + 2
        while list(state.glob('transcript-index.*')) and time.monotonic() < settle:
            time.sleep(.05)
        assert not list(state.glob('transcript-index.*')), 'partial cache/temp survived timeout'
        print('PASS timed-out worker group reaped; no partial cache or private file', flush=True)
finally:
    for p in workers:
        try:
            os.killpg(p if isinstance(p, int) else p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    shutil.rmtree(tmp)
