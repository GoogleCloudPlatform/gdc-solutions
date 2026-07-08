#!/usr/bin/env python3
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import argparse
import os
import re
import ssl
import subprocess
import sys
import urllib.request
from html.parser import HTMLParser


class HTMLToMarkdown(HTMLParser):
    def __init__(self):
        super().__init__()
        self.markdown = []
        self.in_style = False
        self.list_stack = []  # Stack of ('ul' or 'ol', index)
        self.table_active = False
        self.table_row = []
        self.table_divider_added = False
        self.in_link = False
        self.link_href = ""
        self.link_text = []

    def handle_starttag(self, tag, attrs):
        attrs_dict = dict(attrs)
        if tag in ["style", "script", "head"]:
            self.in_style = True
            return

        if self.in_style:
            return

        if tag in ["h1", "h2", "h3", "h4", "h5", "h6"]:
            level = int(tag[1])
            self.markdown.append(f"\n\n" + "#" * level + " ")
        elif tag == "p":
            self.markdown.append("\n\n")
        elif tag in ["strong", "b"]:
            self.markdown.append("**")
        elif tag in ["em", "i"]:
            self.markdown.append("*")
        elif tag == "a":
            self.in_link = True
            self.link_href = attrs_dict.get("href", "")
            self.link_text = []
        elif tag == "ul":
            self.list_stack.append(("ul", 0))
            self.markdown.append("\n")
        elif tag == "ol":
            self.list_stack.append(("ol", 1))
            self.markdown.append("\n")
        elif tag == "li":
            indent = "  " * (len(self.list_stack) - 1)
            if self.list_stack:
                list_type, index = self.list_stack[-1]
                if list_type == "ul":
                    self.markdown.append(f"\n{indent}- ")
                else:
                    self.markdown.append(f"\n{indent}{index}. ")
                    self.list_stack[-1] = (list_type, index + 1)
            else:
                self.markdown.append("\n- ")
        elif tag == "br":
            self.markdown.append("\n")
        elif tag == "table":
            self.table_active = True
            self.table_divider_added = False
            self.markdown.append("\n\n")
        elif tag == "tr":
            self.table_row = []
        elif tag in ["td", "th"]:
            # Start capturing cell data
            self.cell_data = []

    def handle_endtag(self, tag):
        if tag in ["style", "script", "head"]:
            self.in_style = False
            return

        if self.in_style:
            return

        if tag in ["h1", "h2", "h3", "h4", "h5", "h6"]:
            self.markdown.append("\n")
        elif tag in ["strong", "b"]:
            self.markdown.append("**")
        elif tag in ["em", "i"]:
            self.markdown.append("*")
        elif tag == "a":
            self.in_link = False
            text = "".join(self.link_text).strip()
            if text:
                # Clean Google redirect links
                href = self.link_href
                if "google.com/url?q=" in href:
                    match = re.search(r"q=([^&]+)", href)
                    if match:
                        from urllib.parse import unquote

                        href = unquote(match.group(1))
                self.markdown.append(f"[{text}]({href})")
            else:
                self.markdown.append(self.link_href)
        elif tag in ["ul", "ol"]:
            if self.list_stack:
                self.list_stack.pop()
            self.markdown.append("\n")
        elif tag == "table":
            self.table_active = False
        elif tag == "tr":
            if self.table_active:
                row_str = "| " + " | ".join(self.table_row) + " |"
                self.markdown.append(row_str + "\n")
                if not self.table_divider_added:
                    divider = "| " + " | ".join(["---"] * len(self.table_row)) + " |"
                    self.markdown.append(divider + "\n")
                    self.table_divider_added = True
        elif tag in ["td", "th"]:
            cell_text = "".join(self.cell_data).replace("\n", " ").strip()
            self.table_row.append(cell_text)

    def handle_data(self, data):
        if self.in_style:
            return

        if self.in_link:
            self.link_text.append(data)
        elif self.table_active and hasattr(self, "cell_data"):
            self.cell_data.append(data)
        else:
            self.markdown.append(data)


def extract_doc_id(url):
    # Extract resourcekey if present
    resource_key = None
    rk_match = re.search(r"resourcekey=([a-zA-Z0-9-_]+)", url)
    if rk_match:
        resource_key = rk_match.group(1)

    # Match standard edit URL
    edit_match = re.search(r"/document/d/([a-zA-Z0-9-_]+)", url)
    if edit_match:
        return edit_match.group(1), False, resource_key

    # Match publish URL
    pub_match = re.search(r"/document/d/e/([a-zA-Z0-9-_]+)", url)
    if pub_match:
        return pub_match.group(1), True, resource_key

    return None, False, None


def get_gcloud_token():
    # Try getting ADC token first (recommended for scripts)
    try:
        result = subprocess.run(
            ["gcloud", "auth", "application-default", "print-access-token"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if result.returncode == 0:
            token = result.stdout.strip()
            if token.startswith("ya29."):
                return token, True
    except Exception:
        pass

    # Fallback to gcloud CLI token
    try:
        result = subprocess.run(
            ["gcloud", "auth", "print-access-token"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if result.returncode == 0:
            token = result.stdout.strip()
            if token.startswith("ya29."):
                return token, False
    except Exception:
        pass
    return None, False


def handle_download_error(e, token, is_adc):
    if hasattr(e, "code") and e.code in [401, 403]:
        print(
            f"Error downloading document: HTTP Error {e.code}: {e.reason}",
            file=sys.stderr,
        )
        if token:
            print(
                "\nNote: Your local credentials may not have the required Google Drive scopes or access permissions.",
                file=sys.stderr,
            )
            print(
                "Try logging in to Application Default Credentials (ADC) with the correct scopes:",
                file=sys.stderr,
            )
            print(
                "  gcloud auth application-default login --scopes=https://www.googleapis.com/auth/drive.readonly,https://www.googleapis.com/auth/cloud-platform",
                file=sys.stderr,
            )
        else:
            print(
                "\nNote: If the document is private, you must share it publicly, download it manually, or log in with credentials.",
                file=sys.stderr,
            )
    else:
        print(f"Error downloading document: {e}", file=sys.stderr)
        print(
            "Note: If the document is private, please share it publicly or download it manually.",
            file=sys.stderr,
        )


def download_google_doc(doc_id, is_pub, resource_key=None):
    token, is_adc = get_gcloud_token()

    if is_pub:
        # Publish URLs only serve HTML
        url = f"https://docs.google.com/document/d/e/{doc_id}/pub"
        if resource_key:
            url += f"?resourcekey={resource_key}"
    else:
        # Edit URLs support native Markdown export
        url = f"https://docs.google.com/document/d/{doc_id}/export?format=md"
        if resource_key:
            url += f"&resourcekey={resource_key}"

    print(f"Downloading from: {url}")

    headers = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"}
    if token:
        print("Using local Google credentials for authentication...")
        headers["Authorization"] = f"Bearer {token}"

    req = urllib.request.Request(url, headers=headers)
    try:
        # Try with default SSL verification first
        with urllib.request.urlopen(req) as response:
            return response.read().decode("utf-8")
    except Exception as e:
        # If it failed due to SSL verification, retry with unverified context
        if "CERTIFICATE_VERIFY_FAILED" in str(e) or "certificate verify failed" in str(
            e
        ):
            print(
                "Warning: SSL certificate verification failed. Retrying with SSL verification disabled...",
                file=sys.stderr,
            )
            try:
                context = ssl._create_unverified_context()
                with urllib.request.urlopen(req, context=context) as response:
                    return response.read().decode("utf-8")
            except Exception as retry_err:
                handle_download_error(retry_err, token, is_adc)
                sys.exit(1)
        else:
            handle_download_error(e, token, is_adc)
            sys.exit(1)


def post_process_markdown(md):
    # Remove excessive newlines
    md = re.sub(r"\n{3,}", "\n\n", md)

    # Fix trailing spaces on lines
    lines = [line.rstrip() for line in md.split("\n")]
    md = "\n".join(lines)

    return md.strip() + "\n"


def convert_html_to_markdown(html_content):
    parser = HTMLToMarkdown()
    parser.feed(html_content)
    md = "".join(parser.markdown)
    return post_process_markdown(md)


def main():
    parser = argparse.ArgumentParser(
        description="Convert a Google Doc (URL or local HTML) to Markdown."
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--url", help="The Google Doc URL (edit or publish format).")
    group.add_argument("--file", help="Path to a locally saved Google Doc HTML file.")
    parser.add_argument(
        "--out", required=True, help="Path where the Markdown file should be written."
    )

    args = parser.parse_args()

    if args.url:
        doc_id, is_pub, resource_key = extract_doc_id(args.url)
        if not doc_id:
            print("Error: Could not extract document ID from URL.", file=sys.stderr)
            sys.exit(1)
        content = download_google_doc(doc_id, is_pub, resource_key)
        if not is_pub:
            print("Processing downloaded Markdown...")
            markdown_content = post_process_markdown(content)
        else:
            print("Converting downloaded HTML to Markdown...")
            markdown_content = convert_html_to_markdown(content)
    else:
        if not os.path.exists(args.file):
            print(f"Error: Local file '{args.file}' not found.", file=sys.stderr)
            sys.exit(1)
        with open(args.file, "r", encoding="utf-8") as f:
            html_content = f.read()
        print("Converting HTML to Markdown...")
        markdown_content = convert_html_to_markdown(html_content)

    # Ensure output directory exists
    out_dir = os.path.dirname(args.out)
    if out_dir and not os.path.exists(out_dir):
        os.makedirs(out_dir)

    with open(args.out, "w", encoding="utf-8") as f:
        f.write(markdown_content)

    print(f"Successfully wrote Markdown to: {args.out}")


if __name__ == "__main__":
    main()
