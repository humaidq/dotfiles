{
  writeScript,
}:
writeScript "i3status-with-orgclock" ''
  #!/usr/bin/env python3
  import json, subprocess, sys, time, shlex

  I3STATUS = "i3status"  # or an absolute path if you prefer

  def elisp(expr: str) -> str:
      try:
          out = subprocess.check_output(
              ["emacsclient", "-a", "", "-e", expr],
              stderr=subprocess.DEVNULL
          ).decode("utf-8").strip()
          # emacsclient wraps lisp string results in quotes; strip them.
          if len(out) >= 2 and out[0] == '"' and out[-1] == '"':
              out = out[1:-1]
          return out
      except Exception:
          return ""

  def get_active_and_total():
      # Active clock string (e.g., "Clocked: (0:10)" etc.)
      cur = elisp(
          "(progn (require 'org-clock)"
          "  (if (org-clocking-p)"
          "      (substring-no-properties (org-clock-get-clock-string))"
          "    \"\"))"
      )

      # Today total minutes across agenda files
      mins_str = elisp(
          "(progn (require 'org) (require 'org-clock)"
          "  (let ((m 0))"
          "    (dolist (f (org-agenda-files))"
          "      (with-current-buffer (find-file-noselect f)"
          "        (setq m (+ m (org-clock-sum-today)))))"
          "    (number-to-string m)))"
      )

      # Parse active minutes from cur; org typically shows "(H:MM)" somewhere.
      # We'll extract H:MM if present; otherwise blank.
      active_mm = ""
      if "(" in cur and ")" in cur:
          try:
              hhmm = cur[cur.index("(")+1:cur.index(")")]
              # Normalize to MM total for active (we only need H:MM display)
              if ":" in hhmm:
                  h, m = hhmm.split(":")
                  h = int(h.strip())
                  m = int(m.strip())
                  active_mm = f"{h:02d}:{m:02d}"
          except Exception:
              active_mm = ""

      try:
          mins = int(mins_str) if mins_str else 0
      except ValueError:
          mins = 0
      total_h, total_m = mins // 60, mins % 60

      return active_mm, f"{total_h:02d}:{total_m:02d}"

  def main():
      # Start i3status and pass through JSON, injecting our block
      p = subprocess.Popen([I3STATUS], stdout=subprocess.PIPE, text=True)

      # i3status protocol header: first two lines (version, then '[')
      header = p.stdout.readline()
      sys.stdout.write(header)
      sys.stdout.flush()
      open_bracket = p.stdout.readline()
      sys.stdout.write(open_bracket)
      sys.stdout.flush()

      last_fetch = 0
      cache = ("", "")  # (active, total)

      while True:
          line = p.stdout.readline()
          if not line:
              break

          # Lines after header are either a comma + JSON array, or just the array.
          prefix = ""
          payload = line
          if payload.startswith(","):
              prefix = ","
              payload = payload[1:]

          try:
              arr = json.loads(payload)
          except json.JSONDecodeError:
              # Just forward if something odd happens
              sys.stdout.write(line)
              sys.stdout.flush()
              continue

          now = time.time()
          if now - last_fetch > 10:  # refresh every ~10s
              cache = get_active_and_total()
              last_fetch = now
          active, total = cache

          if active:
              text = f"A: {active} | T: {total}"
          else:
              text = f"A: --:-- | T: {total}"

          org_block = {
              "name": "orgclock",
              "full_text": text,
              # Optional cosmetics for swaybar (hex color)
              # "color": "#eeeeee",
          }

          # Prepend our block
          new_arr = [org_block] + arr

          out = json.dumps(new_arr, ensure_ascii=False)
          sys.stdout.write(prefix + out + "\n")
          sys.stdout.flush()

  if __name__ == "__main__":
      main()

''
