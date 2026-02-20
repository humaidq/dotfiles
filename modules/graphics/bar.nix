{
  i3status,
  writeScriptBin,
}:
writeScriptBin "i3status-with-orgclock" ''
  #!/usr/bin/env python3
  import json
  import re
  import subprocess
  import sys
  import time

  I3STATUS = "${i3status}/bin/i3status"

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

  def to_hhmm(minutes: int) -> str:
      h, m = divmod(max(minutes, 0), 60)
      return f"{h:02d}:{m:02d}"

  def shorten(text: str, limit: int = 40) -> str:
      text = text.strip()
      if len(text) <= limit:
          return text
      return text[: limit - 3] + "..."

  def strip_org_links(text: str) -> str:
      if not text:
          return ""
      text = re.sub(r"\[\[[^\[\]]+\]\[([^\[\]]+)\]\]", r"\1", text)
      text = re.sub(r"\[\[[^\[\]]+\]\]", "", text)
      return " ".join(text.split())

  def parse_active_minutes(clock_str: str):
      match = re.search(r"\[(\d+):(\d{2})\]", clock_str)
      if not match:
          match = re.search(r"\((\d+):(\d{2})\)", clock_str)
      if not match:
          return None
      try:
          return int(match.group(1)) * 60 + int(match.group(2))
      except ValueError:
          return None

  def get_clock_state():
      is_active = (
          elisp(
              "(progn (require 'org-clock)"
              "  (if (org-clocking-p) \"1\" \"0\"))"
          )
          == "1"
      )

      active_minutes = None
      task_title = ""

      if is_active:
          active_minutes_str = elisp(
              "(progn (require 'org-clock)"
              "  (if (org-clocking-p)"
              "      (number-to-string (org-clock-get-clocked-time))"
              "    \"\"))"
          )
          try:
              active_minutes = int(active_minutes_str)
          except ValueError:
              active_minutes = None

          if active_minutes is None:
              clock_str = elisp(
                  "(progn (require 'org-clock)"
                  "  (if (org-clocking-p)"
                  "      (substring-no-properties (org-clock-get-clock-string))"
                  "    \"\"))"
              )
              active_minutes = parse_active_minutes(clock_str)

          task_title = elisp(
              "(progn (require 'org-clock)"
              "  (if (org-clocking-p)"
              "      (substring-no-properties (or org-clock-current-task \"\"))"
              "    \"\"))"
          )
          task_title = strip_org_links(task_title)

      # Today total minutes across agenda files
      mins_str = elisp(
          "(progn (require 'org) (require 'org-clock)"
          "  (let ((m 0))"
          "    (dolist (f (org-agenda-files))"
          "      (with-current-buffer (find-file-noselect f)"
          "        (setq m (+ m (org-clock-sum-today)))))"
          "    (number-to-string m)))"
      )

      try:
          mins = int(mins_str) if mins_str else 0
      except ValueError:
          mins = 0

      if active_minutes is not None:
          mins += active_minutes

      return is_active, active_minutes, shorten(task_title), mins

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
      cache = (False, None, "", 0)  # (is_active, active_minutes, title, total_minutes)

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
              cache = get_clock_state()
              last_fetch = now
          is_active, active_minutes, task_title, total_minutes = cache

          text = ""
          if is_active:
              active = to_hhmm(active_minutes or 0)
              total = to_hhmm(total_minutes)
              if task_title:
                  text = f"A: {active} | T: {total} | {task_title}"
              else:
                  text = f"A: {active} | T: {total}"
          elif total_minutes > 0:
              text = f"T: {to_hhmm(total_minutes)}"

          if text:
              org_block = {
                  "name": "orgclock",
                  "full_text": text,
                  # Optional cosmetics for swaybar (hex color)
                  # "color": "#eeeeee",
              }
              # Prepend our block
              new_arr = [org_block] + arr
          else:
              new_arr = arr

          out = json.dumps(new_arr, ensure_ascii=False)
          sys.stdout.write(prefix + out + "\n")
          sys.stdout.flush()

  if __name__ == "__main__":
      main()

''
