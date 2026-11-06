# mask-commit-message.awk — prints a shell command with the message of every
# `git ... commit -m/--message` replaced by MSG, so the warn-tier checks read
# the command and not the prose describing it ("fix: drop table on rollback").
#
# Usage: printf '%s' "$CMD" | awk -f mask-commit-message.awk
#
# Masking hides text from the checks, so anything the scanner cannot read with
# certainty comes back UNCHANGED: command substitution, backticks, $'...',
# heredocs (other than the quoted `-m "$(cat <<'EOF' ... EOF)"` message form),
# process substitution, unterminated quotes, and a commit whose output is piped
# onward (`git commit -m 'rm -rf x' | sh` runs the message).

{ src = (NR == 1) ? $0 : src "\n" $0 }
END { printf "%s", mask(src) }

function start_word(pos) {
  if (inword) return
  inword = 1
  nt++
  kind[nt] = "w"; tstart[nt] = pos; tval[nt] = ""; heredoc[nt] = 0
}

function end_word(pos) {
  if (!inword) return
  inword = 0
  tend[nt] = pos
}

function add_tok(k, text, pos) {
  nt++
  kind[nt] = k; tval[nt] = text; tstart[nt] = pos; tend[nt] = pos + length(text) - 1; heredoc[nt] = 0
}

# A ${...} expansion is copied as-is unless it nests quoting the scanner would
# have to follow; returns its length, or 0 to give up.
function brace_len(s, i,    j, inner) {
  j = index(substr(s, i + 2), "}")
  if (!j) return 0
  inner = substr(s, i + 2, j - 1)
  if (inner ~ /["'`]/ || index(inner, "$(")) return 0
  return j + 2
}

# bash 3.2 (still /bin/bash and /bin/sh on macOS) finds the end of $( by
# pairing parens and quotes inside the heredoc body, so a stray `)` there ends
# the substitution and runs the rest. Only a body every shell reads as plain
# text is masked: no quotes, backslash, $ or #, and balanced parens.
function plain_body(t,    i, c, depth) {
  if (t ~ /["'`\\$#]/) return 0
  depth = 0
  for (i = 1; i <= length(t); i++) {
    c = substr(t, i, 1)
    if (c == "(") depth++
    else if (c == ")" && --depth < 0) return 0
  }
  return depth == 0
}

# The one heredoc a commit message may use: -m "$(cat <<'EOF' ... EOF\n)".
# Its body is literal text. Returns the construct's length, or 0.
function heredoc_len(s, i,    rest, head, delim, dash, body, pos, nl, line, after, tail) {
  rest = substr(s, i)
  if (!match(rest, /^"\$\(cat[ \t]+<<-?[ \t]*['"][A-Za-z_][A-Za-z0-9_]*['"][ \t]*\n/)) return 0
  head = substr(rest, 1, RLENGTH)
  body = substr(rest, RLENGTH + 1)
  dash = (head ~ /<<-/)
  delim = head
  sub(/^"\$\(cat[ \t]+<<-?[ \t]*['"]/, "", delim)
  sub(/['"][ \t]*\n$/, "", delim)
  pos = 1
  while (pos <= length(body)) {
    nl = index(substr(body, pos), "\n")
    line = nl ? substr(body, pos, nl - 1) : substr(body, pos)
    if (dash) sub(/^\t+/, "", line)
    if (line == delim) {
      if (!plain_body(substr(body, 1, pos - 1))) return 0
      after = nl ? pos + nl : length(body) + 1
      tail = substr(body, after)
      if (!match(tail, /^[ \t\n]*\)"/)) return 0
      return length(head) + after - 1 + RLENGTH
    }
    if (!nl) return 0
    pos += nl
  }
  return 0
}

function mask(s,    L, i, c, c2, j, sep, op, a, b, k, p, pre, rest, out, prev, hit, masked) {
  L = length(s); i = 1; nt = 0; inword = 0
  while (i <= L) {
    c = substr(s, i, 1)
    c2 = substr(s, i + 1, 1)
    if (c == " " || c == "\t") { end_word(i - 1); i++; continue }
    if (c == "\\") {
      if (c2 == "\n") { end_word(i - 1); i += 2; continue }
      if (i == L) return s
      start_word(i); tval[nt] = tval[nt] c2; i += 2; continue
    }
    if (c == "&" && c2 == ">") { end_word(i - 1); add_tok("op", "&>", i); i += 2; continue }
    if (c == "\n" || c == ";" || c == "&" || c == "|" || c == "(" || c == ")") {
      end_word(i - 1)
      sep = c
      if ((c == "&" && c2 == "&") || (c == "|" && (c2 == "|" || c2 == "&")) || (c == ";" && c2 == ";")) sep = c c2
      add_tok("sep", sep, i); i += length(sep); continue
    }
    if (c == "<" || c == ">") {
      if (c == "<" && c2 == "<") return s
      if (c2 == "(") return s
      end_word(i - 1)
      op = c
      if (c2 == ">" || c2 == "&" || c2 == "|" || (c == "<" && c2 == ">")) op = c c2
      add_tok("op", op, i); i += length(op); continue
    }
    if (c == "#" && !inword) {
      j = index(substr(s, i), "\n")
      if (!j) break
      i += j - 1; continue
    }
    if (c == "`") return s
    if (c == "$") {
      if (c2 == "'" || c2 == "(") return s
      if (c2 == "{") {
        j = brace_len(s, i)
        if (!j) return s
        start_word(i); tval[nt] = tval[nt] substr(s, i, j); i += j; continue
      }
    }
    if (c == "'") {
      start_word(i)
      j = index(substr(s, i + 1), "'")
      if (!j) return s
      tval[nt] = tval[nt] substr(s, i + 1, j - 1); i += j + 1; continue
    }
    if (c == "\"") {
      if (!inword && (j = heredoc_len(s, i))) {
        start_word(i); heredoc[nt] = 1; tval[nt] = "MSG"; i += j; continue
      }
      start_word(i); i++
      while (1) {
        if (i > L) return s
        c = substr(s, i, 1); c2 = substr(s, i + 1, 1)
        if (c == "\"") { i++; break }
        if (c == "\\") {
          if (c2 == "\n") { i += 2; continue }
          if (c2 == "\\" || c2 == "\"" || c2 == "$" || c2 == "`") { tval[nt] = tval[nt] c2; i += 2; continue }
          tval[nt] = tval[nt] c; i++; continue
        }
        if (c == "`") return s
        if (c == "$" && c2 == "(") return s
        if (c == "$" && c2 == "{") {
          j = brace_len(s, i)
          if (!j) return s
          tval[nt] = tval[nt] substr(s, i, j); i += j; continue
        }
        tval[nt] = tval[nt] c; i++
      }
      continue
    }
    start_word(i); tval[nt] = tval[nt] c; i++
  }
  end_word(L)

  # One segment at a time: tokens a..b between separators.
  a = 1
  while (a <= nt) {
    b = a
    while (b <= nt && kind[b] != "sep") b++
    k = a
    while (k < b && kind[k] == "w" && tval[k] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) k++
    if (k < b && kind[k] == "w" && (tval[k] == "git" || tval[k] ~ /\/git$/)) {
      k++
      while (k < b && kind[k] == "w" && tval[k] ~ /^-/) {
        if (tval[k] ~ /^(-C|-c|--git-dir|--work-tree|--namespace|--config-env|--super-prefix)$/) k += 2
        else k++
      }
      if (k < b && kind[k] == "w" && tval[k] == "commit") {
        hit = 0
        for (j = k + 1; j < b; j++) {
          if (kind[j] == "op") { j++; continue }
          if (tval[j] == "--") break
          if (tval[j] ~ /^--message=/) { masked[j] = "--message=MSG"; hit = 1; continue }
          if (tval[j] == "--message") {
            if (j + 1 < b && kind[j + 1] == "w") { masked[j + 1] = "MSG"; hit = 1 }
            j++; continue
          }
          if (tval[j] ~ /^-[^-]/) {
            p = index(substr(tval[j], 2), "m")
            if (!p) continue
            pre = substr(tval[j], 2, p - 1)
            # A short option that takes a value ends the cluster before -m.
            if (pre ~ /[cCFtSu]/) continue
            rest = substr(tval[j], p + 2)
            if (rest != "") { masked[j] = "-" pre "mMSG"; hit = 1; continue }
            if (j + 1 < b && kind[j + 1] == "w") { masked[j + 1] = "MSG"; hit = 1 }
            j++; continue
          }
        }
        if (hit && b <= nt && (tval[b] == "|" || tval[b] == "|&")) return s
      }
    }
    a = b + 1
  }

  for (j = 1; j <= nt; j++)
    if (heredoc[j] && !(j in masked)) return s

  out = ""; prev = 1
  for (j = 1; j <= nt; j++) {
    if (!(j in masked)) continue
    out = out substr(s, prev, tstart[j] - prev) masked[j]
    prev = tend[j] + 1
  }
  return out substr(s, prev)
}
