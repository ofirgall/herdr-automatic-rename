# transcript.sh - what a coding agent's own session says it is about.
#
# Sourced by automatic-rename.sh, beside naming.sh, icons.sh and git.sh. Like
# git.sh it reads the filesystem, which is why it is in neither of the other two.
# Unlike git.sh it is not cheap -- two bounded reads and a jq -- so where that
# module is called for every named tab, this one is called only where a pane has
# an agent, a session id, and a terminal title that said nothing. A titled agent
# never reaches it.
#
# An agent that has titled its terminal has already said what it is doing, and
# AGENT_TITLES reads that (see ar_title_clean). This answers when it has not,
# which is a repeatable case rather than an edge: Claude Code derives its
# terminal title from what the user typed, so a session opened with a slash
# command and answered by the agent alone is never given one, and its tab reads
# "claude" however long it runs.
#
# Claude Code and Cursor are read, and the pane's agent is checked rather than
# assumed: every agent keeps its sessions in its own shape and its own place, so
# another agent's pane carrying a session value -- its own, or one a claude left
# behind there -- would otherwise put one agent's prompts on another agent's tab.
# The shapes are undocumented besides, so a session that stops carrying these
# fields yields nothing and the tab is named as it was before this existed, which
# is the failure mode to have.
#
# Checked on its own by shellcheck, where the AR_TRANSCRIPT_* globals it answers
# through have no reader in sight: the engine next door is what reads them.
# shellcheck disable=SC2034

# The agents whose sessions this knows how to read, as herdr names them.
AR_TRANSCRIPT_AGENT=claude
AR_CURSOR_AGENT=cursor

# Where Claude Code keeps its sessions. The environment variable is what a user
# who moved it sets, and it is read at call time rather than cached because the
# shell hook and the reconcile are different processes with different environments.
ar_transcript_root() {
  printf '%s' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
}

# The shape of a session id. It arrives over the socket and becomes part of a
# path, so anything else is refused rather than cleaned.
_AR_SESSION_ID='^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'

# How much of a transcript is read. The last title is at the end (a session is
# renamed as it goes) and the first prompt is at the start, so each read takes
# the end it needs rather than the file: a long session's transcript runs to
# megabytes, and this can run once per untitled agent tab per event.
_AR_TRANSCRIPT_TAIL=262144
_AR_TRANSCRIPT_HEAD=65536

# What a transcript line says about the session, for the read that wants the
# opening prompt. The read that wants the title needs none of it.
#
# `fromjson? // empty` is what makes a partial line -- both reads cut one, and
# the agent may be writing another -- a line that is skipped rather than an error
# that loses the whole read.
AR_JQ_TRANSCRIPT='
def content: .message.content
  | if type == "string" then .
    elif type == "array" then ([ .[] | select(.type == "text") | .text ] | join(" "))
    else "" end;
# What the user actually typed, as against a slash command expanded into the
# conversation as further user messages, a tool answering with its output, or the
# caveat a resumed session opens with. Newer transcripts mark it; older ones
# carry no marker at all, and there a message whose content is a plain STRING is
# the same thing by another road -- everything the tool injects arrives as blocks.
def typed: .type == "user"
  and ((.origin.kind == "human") or ((.message.content | type) == "string"));
# A slash command is recorded with its name and its arguments beside it, and
# "code-review spec.md" says which review is running where the command alone does
# not. Anything else has the blocks the tool wrapped around it taken off: the
# expansion of a command, the caveat on a resumed session.
def opening:
  if test("<command-name>") then
    ((capture("<command-name>[[:space:]]*/?(?<n>[^<[:space:]]+)").n // "")
     + " " + ((capture("(?s)<command-args>(?<a>.*?)</command-args>").a // "")
              | split("\n")[0] // ""))
  else
    gsub("(?s)<[a-z][a-z-]*>.*?</[a-z][a-z-]*>"; " ")
  end
  | split("\n")[0] // "";
'

# ar_transcript_file <session id> <pane directory> -> sets AR_TRANSCRIPT_FILE to
# the transcript of that session; rc 1 when there is none to read.
#
# Claude Code files a session under the directory it was started in, which is
# usually the pane's, so that is tried before the scan across every project.
ar_transcript_file() {
  local root slug match
  AR_TRANSCRIPT_FILE=""
  [[ $1 =~ $_AR_SESSION_ID ]] || return 1
  root=$(ar_transcript_root)
  # How Claude Code names a project directory: every character that is not a
  # letter or a digit becomes a dash, the leading separator included.
  slug=${2//[!a-zA-Z0-9]/-}
  if [ -n "$slug" ] && [ -f "$root/$slug/$1.jsonl" ]; then
    AR_TRANSCRIPT_FILE="$root/$slug/$1.jsonl"
    return 0
  fi
  # A pane that has changed directory since the session started files it
  # elsewhere, and only the whole projects directory says where.
  for match in "$root"/*/"$1.jsonl"; do
    if [ -f "$match" ]; then
      AR_TRANSCRIPT_FILE=$match
      return 0
    fi
  done
  return 1
}

# ar_transcript_topic <pane agent> <session id> <pane directory>
#   -> sets AR_TRANSCRIPT_TOPIC to what the session says it is about, and
#      AR_TRANSCRIPT_TOPIC_LC to the same folded for comparison; rc 1 when it
#      says nothing.
#
# Two things in a transcript can name a session, and they are read in that order:
#
#   `ai-title`, the title Claude Code generates and puts in its terminal title.
#   The last one wins, because a session is renamed as it goes.
#
#   failing that, the first prompt the user actually typed, which is what Claude
#   Code's own session list shows for a session with no title.
#
# Both come back through the same jq the pane's own title goes through (`task`),
# so a topic reaches ar_title_clean in the shape that function documents: cleaned
# of control characters, with its leading run of non-alphanumerics off, and
# folded by jq rather than by a byte-wise fold that would mishandle a non-ASCII
# first letter.
ar_transcript_topic() {
  local row=""
  AR_TRANSCRIPT_TOPIC=""
  AR_TRANSCRIPT_TOPIC_LC=""
  [ "${AGENT_TRANSCRIPT:-1}" = "1" ] || return 1
  if [ "$1" = "$AR_CURSOR_AGENT" ]; then
    ar_cursor_topic "$2"
    return
  fi
  [ "$1" = "$AR_TRANSCRIPT_AGENT" ] || return 1
  ar_transcript_file "$2" "$3" || return 1
  # `last(inputs)` and `first(inputs)` rather than a trailing `tail -n1`/`head
  # -n1`: the answer is picked inside the jq that is already running, which is
  # two processes fewer, and `first` stops the read at the opening prompt instead
  # of scanning the rest of the window for lines it would throw away.
  row=$(tail -c "$_AR_TRANSCRIPT_TAIL" "$AR_TRANSCRIPT_FILE" 2>/dev/null \
    | jq -Rrn "$AR_JQ_CLEAN$AR_JQ_TASK"'
      last(inputs | fromjson? // empty
        | select(.type == "ai-title") | .aiTitle | strings | select(length > 0))
      // empty | task("") | select(length > 0)
      | [ ., ascii_downcase ] | join([31] | implode)' 2>/dev/null)
  if [ -z "$row" ]; then
    row=$(head -c "$_AR_TRANSCRIPT_HEAD" "$AR_TRANSCRIPT_FILE" 2>/dev/null \
      | jq -Rrn "$AR_JQ_CLEAN$AR_JQ_TASK$AR_JQ_TRANSCRIPT"'
        first(inputs | fromjson? // empty | select(typed)
          | content | opening | task("") | select(length > 0))
        // empty | [ ., ascii_downcase ] | join([31] | implode)' 2>/dev/null)
  fi
  [ -n "$row" ] || return 1
  IFS=$AR_ROW_SEP read -r AR_TRANSCRIPT_TOPIC AR_TRANSCRIPT_TOPIC_LC <<< "$row"
  [ -n "$AR_TRANSCRIPT_TOPIC" ]
}

# Where Cursor keeps its chats, one directory per chat id under a directory per
# workspace. CURSOR_CONFIG_DIR is the same override herdr's cursor integration
# honours.
ar_cursor_chats_root() {
  printf '%s' "${CURSOR_CONFIG_DIR:-$HOME/.cursor}/chats"
}

# The name Cursor gives a chat before its first prompt. It says nothing about the
# work, so it is refused like a title that names the agent.
_AR_CURSOR_UNNAMED='New Agent'

# ar_cursor_topic <session id> -> sets AR_TRANSCRIPT_TOPIC(_LC) to the name
# Cursor generated for that chat; rc 1 when there is none.
#
# herdr's cursor integration reports the chat id as the pane's session. Cursor
# files the chat under md5(workspace root), and the root is not always the pane's
# directory, so the chat is found by its id across every workspace: there is one
# match, and a glob costs less than hashing a guess. The name lives in the chat's
# store.db as hex-encoded JSON in the meta table. The read is read-only but not
# immutable: the running agent writes through a WAL, and the name it just
# generated may still be there.
ar_cursor_topic() {
  local match db="" row=""
  [[ $1 =~ $_AR_SESSION_ID ]] || return 1
  command -v sqlite3 >/dev/null 2>&1 || return 1
  for match in "$(ar_cursor_chats_root)"/*/"$1"/store.db; do
    if [ -f "$match" ]; then
      db=$match
      break
    fi
  done
  [ -n "$db" ] || return 1
  row=$(sqlite3 -readonly "$db" \
      "SELECT CAST(unhex(value) AS TEXT) FROM meta LIMIT 1" 2>/dev/null \
    | jq -Rrn --arg unnamed "$_AR_CURSOR_UNNAMED" "$AR_JQ_CLEAN$AR_JQ_TASK"'
      first(inputs | fromjson? // empty | .name | strings
        | select(length > 0 and . != $unnamed))
      // empty | task("") | select(length > 0)
      | [ ., ascii_downcase ] | join([31] | implode)' 2>/dev/null)
  [ -n "$row" ] || return 1
  IFS=$AR_ROW_SEP read -r AR_TRANSCRIPT_TOPIC AR_TRANSCRIPT_TOPIC_LC <<< "$row"
  [ -n "$AR_TRANSCRIPT_TOPIC" ]
}
