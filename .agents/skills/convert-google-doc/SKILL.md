---
name: convert-google-doc
description: Convert a Google Doc URL to a Markdown file in the repository. Trigger this skill whenever a user provides a Google Doc link and asks to convert, import, or save it to markdown.
---

# Convert Google Doc to Markdown

This skill converts a Google Doc URL (or a manually downloaded Google Doc HTML file) into a clean, GitHub-compatible Markdown file formatted for this repository.

## Triggering the Skill
Use this skill when the user asks to:
- Convert a Google Doc link to Markdown.
- Import a Google Doc into the repository.
- Copy content from a Google Doc URL.

## Instructions

### Step 1: Run the Conversion Script
You can use the built-in python script `convert.py` in this skill to download and parse the Google Doc:

```bash
python3 .agents/skills/convert-google-doc/scripts/convert.py --url "<GOOGLE_DOC_URL>" --out "<OUTPUT_PATH>"
```

*Note: Replace `<GOOGLE_DOC_URL>` with the user's URL, and `<OUTPUT_PATH>` with the target destination in the workspace.*

### Step 2: Handling Private Documents (Authentication Failures)
If the Google Doc is private, the download will fail. In this case, follow these steps:
1. Explain to the user that the document is private.
2. Ask them to either:
   - Make the document publicly viewable (e.g., "Anyone with the link can view").
   - Or download the document manually as HTML (`File > Download > Web Page (.html, zipped)`), unzip it, place the `.html` file inside the repository, and provide you with its path.
3. Once they provide the local HTML path, run the script using the `--file` flag:
   ```bash
   python3 .agents/skills/convert-google-doc/scripts/convert.py --file "<PATH_TO_LOCAL_HTML>" --out "<OUTPUT_PATH>"
   ```

### Step 3: Post-Process and Clean Up the Markdown
After the script runs, check the output file. You must review the converted Markdown and clean up any formatting artifacts:
- **Heading Hierarchy**: Ensure the file begins with a single `#` header as the title, followed by `##` and `###`.
- **Code Blocks**: If the Google Doc contains code, it might have been parsed as normal text. Put it inside proper Markdown code blocks (e.g., ` ```bash ` or ` ```yaml `) with appropriate syntax highlighting.
- **Images**: If the document contains images, they are exported to a local folder or referenced. Make sure any image references are pointing to valid, stored files in the repository.
- **Tables**: Ensure all tables are correctly formatted in standard GitHub Markdown table syntax.

### Step 4: Verify Formatting and Spelling
Ensure the final Markdown complies with the repository rules:
- Trim trailing whitespaces from lines.
- Ensure the file ends with a single trailing newline.
- Check spelling and add any custom words to the spellcheck dictionary [.github/dictionary/gdc-solutions.txt](file:///Users/rueth/Development/gdc-solutions/.github/dictionary/gdc-solutions.txt).
