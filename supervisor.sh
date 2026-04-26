#!/bin/bash

# Copyright (C) 2026 Caleb L. Power <cpower@axonibyte.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

IDLE_GRACE=${1:-600}

TAG=2.0.55
TARBALL=https://github.com/Thunder-Compute/thunder-cli/releases/download/v${TAG}/tnr_${TAG}_linux_amd64.tar.gz
BINDIR=~/.local/bin
TNR=${BINDIR}/tnr
LLAMA=/home/ubuntu/llama.cpp/build/bin/llama-server
MODEL=/home/ubuntu/models/DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf
MODEL_EPHEMERAL=/ephemeral/DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf
LOG=/tmp/llama.log
SNAPSHOT=deepseek_r4

mkdir -p $BINDIR

# Ensure we don't read a stale state file from a previous run
rm -f /tmp/llama.ready

if [ ! -f $TNR ] || [ "$($TNR --version | cut -d' ' -f3)" != "${TAG}" ]; then
  printf '> updating tnr to v%s\n' $TAG
  curl -fsSL $TARBALL | tar xvzf - -C $BINDIR tnr && chmod +x $TNR
else
  printf '> tnr is up to date (v%s)\n' $TAG
fi

if [ ! -f $MODEL_EPHEMERAL ]; then
  printf '> copying model to ephemeral disk\n'
  cp $MODEL $MODEL_EPHEMERAL
fi

pid="$(ps -eo pid,args | sed -n -e '/[l]lama-server/{ s/^[[:space:]]*\([0-9][0-9]*\).*/\1/p; q; }' -e '$ s/.*/-1/p')"

if [ "-1" == "${pid}" ]; then
  printf '> launching llama... '
  nohup $LLAMA \
      -m $MODEL_EPHEMERAL \
      --host 127.0.0.1 \
      --port 8080 \
      -ngl 99 \
      -t 32 \
      --mlock \
      --no-mmap > $LOG 2>&1 &
  pid="$(ps -eo pid,args | sed -n -e '/[l]lama-server/{ s/^[[:space:]]*\([0-9][0-9]*\).*/\1/p; q; }' -e '$ s/.*/-1/p')"
  printf '(pid %s)\n' $pid
else
  printf '> llama is already running (pid %s)\n' $pid
fi

while true; do
  ps $pid > /dev/null 2>&1
  if [ "$?" != "0" ]; then
    printf '> llama has died!\n'
    exit 2
  fi

  printf '> checking on llama (request sent %s)... ' "$(date '+%Y-%m-%d %H:%M')"

  res="$(curl -s http://localhost:8080/v1/chat/completions \
      -H "Content-Type: application/json" \
      -d '{"model": "deepseek", "messages": [{"role": "user", "content": "Are you ready to get to work?"}], "temperature": 0.4}')"
  if [ "$?" != "0" ]; then
    printf 'still waiting (api not ready)\n'
  else
    if [ "false" == "$(printf '%s' "$res" | jq -r 'has(".error")')" ]; then
      printf 'ready! (port 8080)\n'
      touch /tmp/llama.ready
      break
    fi

    error="$(printf '%s' "$res" | jq -rc '.error')"
    if [ "null" == "error" ]; then
      printf 'ready! (port 8080)\n'
      touch /tmp/llama.ready
      break
    fi

    error="$(printf '%s' "$res" | jq -rc '.error.type')"
    if [ "unavailable_error" == "$error" ]; then
      printf 'still waiting (model not ready)\n'
    else
      printf 'uh-oh!\n> unexpected llama error: %s\n' "$(echo $error | jq -rc '.message')"
    fi

  fi
  sleep 10
done

while true; do
  ps $pid > /dev/null 2>&1
  if [ "$?" != "0" ]; then
    printf '> llama has died!\n'
    exit 2
  fi

  if [ ! -f $LOG ]; then
    printf '> err: missing %s\n' $LOG 1>&2
  else
    current_mod_ts=$(stat -c %Y "$LOG")
    now=$(date +%s)
    idle_time=$((now - current_mod_ts))

    if [ "$idle_time" -ge "$IDLE_GRACE" ]; then
      printf '> llm has been idle for %d seconds (limit: %d). shutting down...\n' "$idle_time" "$IDLE_GRACE"
      instance_id=$(tnr status --json 2>/dev/null | jq -rc 'first(.[] | select(.template == "'"$SNAPSHOT"'") | .id)')
      if [ "" == "$instance_id" ]; then
        printf '> err: missing instance identifier\n' 1>&2
      else
        printf '> shutting down instance %s\n' "$instance_id"
        tnr delete $instance_id
      fi
    else
      printf '> llm is active (idle for %d seconds, checked %s)\n' "$idle_time" "$(date '+%Y-%m-%d %H:%M')"
    fi
  fi
  sleep 60
done
