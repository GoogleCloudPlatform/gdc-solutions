#!/usr/bin/env python3
import sys
import os

def main():
  if len(sys.argv) < 2:
    return

  for path in sys.argv[1:]:
    try:
      # Skip binary files
      try:
        with open(path, "rb") as f:
          chunk = f.read(1024)
        if b"\0" in chunk:
          continue
      except:
        continue

      with open(path, "rb") as f:
        content = f.read()

      lines = content.splitlines()

      # Check if we should trim trailing whitespace
      _, ext = os.path.splitext(path.lower())
      is_markdown = ext in (".md", ".markdown")

      new_lines = []
      for line in lines:
        if is_markdown:
          # For markdown, only strip \r (windows line endings)
          new_lines.append(line.rstrip(b"\r"))
        else:
          # For others, strip \r and spaces/tabs
          new_lines.append(line.rstrip(b"\r "))

      if new_lines:
        new_content = b"\n".join(new_lines) + b"\n"
      else:
        new_content = b""

      if new_content != content:
        with open(path, "wb") as f:
          f.write(new_content)
        print(f"Fixed whitespace/EOF in: {path}")
    except Exception as e:
      print(f"Error processing {path}: {e}", file=sys.stderr)

if __name__ == "__main__":
  main()
