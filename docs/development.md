# Local Development Setup Guide

If you cannot use the provided Dev Container, you can configure your local
environment manually. This guide outlines the required tools and steps to set up
your system for development and contributing to this repository.

## Prerequisites

You need the following tools installed on your local machine:

1. **Terraform** (version `1.5.7` or higher)
2. **Google Cloud SDK** (version `483.0.0` or higher)
3. **Python 3** (version `3.11.x` recommended)
4. **Black** (Python code formatter)
5. **isort** (Python import sorting tool)
6. **Node.js** (version `20` or higher) & **npm**
7. **ShellCheck** (for linting shell scripts)
8. **shfmt** (for formatting shell scripts)
9. **Lefthook** (git hooks manager to run pre-commit checks)

---

## Installation & Setup

We provide a unified script `.devcontainer/install-tools.sh` to install all
necessary development tools (pyenv, Python, fnm, Node.js, tfswitch, terraform,
gcloud, shellcheck, shfmt) and project dependencies.

### 1. Run the Installation Script

Run the script from the repository root.

#### Option A: Quick Install (Recommended)

If you already have system build dependencies installed (or are on macOS with
Xcode Command Line Tools already configured), run:

```bash
./.devcontainer/install-tools.sh
```

#### Option B: Install with System Dependencies

If you want the script to attempt to install system package dependencies
(requires `sudo` on Linux):

```bash
./.devcontainer/install-tools.sh --sys-deps
```

### 2. Configure Your Shell Profile

After the script completes, it will output environment variables that you need
to add to your shell profile (e.g., `~/.bashrc` or `~/.zshrc`).

Typically, you will need to add lines similar to these:

```bash
export PATH="${HOME}/.local/bin:${PATH}"
export PYENV_ROOT="${HOME}/.pyenv"
[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
eval "$(pyenv init -)"
export PATH="${HOME}/.local/share/fnm:$PATH"
eval "$(fnm env --shell bash)" # use --shell zsh if using zsh
export PATH="${HOME}/google-cloud-sdk/bin:$PATH"
```

Apply the changes to your current session:

```bash
source ~/.bashrc # or source ~/.zshrc
```

### 3. Initialize Git Hooks (Lefthook)

This repository uses [Lefthook](https://github.com/evilmartians/lefthook) to run
formatters and linters automatically on every commit. Since the installation
script symlinks `lefthook` to your local bin, you can enable the git hooks by
running:

```bash
lefthook install
```

---

## Running Quality Checks Manually

You can manually trigger the pre-commit hooks at any time to verify your changes
before committing them:

```bash
# Run all pre-commit hooks on staged files
lefthook run pre-commit

# Run all pre-commit hooks on all files in the repository
lefthook run pre-commit --all-files
```

This will run:

- Whitespace and EOF fixers
- Code formatters (`prettier`, `terraform fmt`, `shfmt`)
- Linters (`shellcheck`)
- Dictionary checks (`check_cspell_dictionaries.sh`)
