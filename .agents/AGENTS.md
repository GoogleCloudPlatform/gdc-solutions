# Gemini Workspace Ruleset - Google Distributed Cloud (GDC) Solutions

This file contains rules and guidelines that Gemini agents must follow when
managing, formatting, and writing code in this repository.

## Documentation and Environment Synchronization

- **Development Guide**: Always keep the local development setup guide
  ([docs/development.md](/docs/development.md)) up-to-date with any manual
  configuration or setup changes introduced in this repository.
- **Synchronization**: Ensure that development tools, dependencies, and
  execution environments described in the local development guide
  ([docs/development.md](/docs/development.md)), defined in the Dev Container
  configuration ([.devcontainer/Dockerfile](/.devcontainer/Dockerfile) and
  [.devcontainer/devcontainer.json](/.devcontainer/devcontainer.json)), and
  registered in the Git hook orchestrator ([lefthook.yml](/lefthook.yml)) are
  kept completely in sync.

## General Formatting Guidelines

- **AGENTS.md Structure**: Always keep this `AGENTS.md` file itself organized
  alphabetically: sort all `##` headers alphabetically, and sort all bullet
  lists alphabetically by their bold names.
- **EditorConfig**: Respect configuration rules defined in the repository's
  `.editorconfig`.
- **Indentation**: Use 2 spaces for indentation. Never use tabs.
- **Line Endings**: Use Unix-style line endings (`LF`).
- **Newlines**: Ensure all text files end with a single trailing newline
  character.
- **Whitespace**: Trim trailing whitespace from all files, except for markdown
  files (`.md`) where trailing whitespace may be used for line breaks.

## JSON and YAML Best Practices

- **Attribute Ordering**: Ensure that all attributes (keys) in JSON and YAML
  files are ordered alphabetically. Always alphabetize the objects and
  attributes in JSON and YAML when possible.

## Python Best Practices (.py)

- **Formatting**: All Python code must be formatted cleanly using the `black`
  formatter.
- **Import Sorting**: All Python imports must be sorted and grouped using the
  `isort` tool with the `black` compatibility profile.
- **Syntax**: Ensure all Python files compile and run under Python 3.11.x.

## Shell Script Best Practices (.sh)

- **Command Substitution**: Prefer `$(command)` over backticks `` `command` ``.
- **Error Handling**: Every shell script entrypoint must start with strict error
  handling. Use:
  ```bash
  set -o errexit
  set -o nounset
  set -o pipefail
  ```
- **Formatting**: Indent with 2 spaces. Keep syntax clean and readable.
- **Quoting**: Quote all variable references (e.g., `"${my_var}"` or
  `"$my_var"`) to prevent word splitting and globbing, except where word
  splitting is explicitly required.
- **Static Analysis**: Verify your shell script modifications against
  `shellcheck` and resolve any warnings before final execution.

## Spelling and Dictionary Management

- **Dictionary Path**: The spelling whitelist is maintained in
  [.github/dictionary/gdc-solutions.txt](file:///.github/dictionary/gdc-solutions.txt).
- **Format**: Entries must be lowercase and maintained in alphabetical order.
  Run the dictionary check script
  [.github/workflows/bin/check_cspell_dictionaries.sh](file:///.github/workflows/bin/check_cspell_dictionaries.sh)
  to verify compliance before finishing.
- **Updates**: Any custom acronyms, abbreviations, or domain-specific terms
  added to code or docs must be appended to the spelling dictionary.

## Terraform Best Practices (.tf)

- **Formatting**: All `.tf` files must be formatted cleanly as if processed by
  `terraform fmt`.
- **Inputs & Outputs**:
  - Always specify the `type` and a clear `description` block for every
    `variable` declaration.
  - Provide a descriptive `description` block for all `output` declarations.
- **Naming Conventions**: Use `snake_case` for all resource names, data source
  names, variable names, and output names.
- **Resource Block Ordering**: Within each resource block, declare arguments
  first, followed by nested blocks, and place `lifecycle` blocks last.
- **Version Pinning**: Always pin providers, backend requirements, and external
  module versions to prevent unexpected breakages on updates.
