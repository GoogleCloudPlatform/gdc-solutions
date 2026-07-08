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

### 1. Install System Dependencies

Choose the package manager or installation method for your operating system:

#### macOS (using Homebrew)

```bash
brew install terraform google-cloud-sdk python@3.11 node shellcheck shfmt lefthook black
```

#### macOS (Manual Setup - without Homebrew)

If Homebrew is not available on your system, you can install the tools manually:

1. **Xcode Command Line Tools** (Required for git, compilers, and python build
   dependencies):

   ```bash
   xcode-select --install
   ```

2. **Terraform**: Download the macOS zip package from the
   [Terraform Downloads Page](https://developer.hashicorp.com/terraform/downloads),
   extract it, and move the `terraform` binary to your `PATH` (e.g.,
   `/usr/local/bin`):

   ```bash
   # For Apple Silicon (M1/M2/M3):
   curl -LO https://releases.hashicorp.com/terraform/1.5.7/terraform_1.5.7_darwin_arm64.zip
   unzip terraform_1.5.7_darwin_arm64.zip
   sudo mv terraform /usr/local/bin/
   rm terraform_1.5.7_darwin_arm64.zip

   # For Intel-based Mac:
   # curl -LO https://releases.hashicorp.com/terraform/1.5.7/terraform_1.5.7_darwin_amd64.zip
   # unzip terraform_1.5.7_darwin_amd64.zip
   # sudo mv terraform /usr/local/bin/
   # rm terraform_1.5.7_darwin_amd64.zip
   ```

3. **Google Cloud SDK**: Install via the official interactive script:

   ```bash
   curl https://sdk.cloud.google.com | bash
   # Restart your shell or run:
   exec -l $SHELL
   ```

4. **Python 3, Black & isort**: Download and run the macOS installer package
   from the [Python Downloads Page](https://www.python.org/downloads/macos/) or
   use `pyenv`:

   ```bash
   curl https://pyenv.run | bash
   # Follow the terminal instructions to add pyenv to your shell profile (.zshrc)
   # Then install and set Python:
   pyenv install 3.11.9
   pyenv global 3.11.9

   # Install the python code formatter and import sorter using the shared dependency configuration
   pip install -r .devcontainer/dependencies/requirements.txt
   ```

5. **Node.js & npm**: Install Node.js (v20) via `fnm` (Fast Node Manager) or
   download the macOS installer (`.pkg`) from [nodejs.org](https://nodejs.org/):

   ```bash
   curl -fsSL https://fnm.vercel.app/install | bash -s -- --force-install
   # Restart your shell, then install Node.js:
   fnm install 20
   fnm default 20
   ```

6. **ShellCheck**: Download the compiled macOS binary from
   [ShellCheck releases](https://github.com/koalaman/shellcheck/releases),
   extract it, and place it in your `PATH`:

   ```bash
   curl -LO https://github.com/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.darwin.x86_64.tar.xz
   tar -xvf shellcheck-v0.10.0.darwin.x86_64.tar.xz
   sudo mv shellcheck-v0.10.0/shellcheck /usr/local/bin/
   rm -rf shellcheck-v0.10.0*
   ```

7. **shfmt**: Download the compiled binary from
   [shfmt releases](https://github.com/mvdan/sh/releases):

   ```bash
   # For Apple Silicon (M1/M2/M3):
   curl -Lo shfmt https://github.com/mvdan/sh/releases/download/v3.8.0/shfmt_v3.8.0_darwin_arm64
   chmod +x shfmt
   sudo mv shfmt /usr/local/bin/

   # For Intel-based Mac:
   # curl -Lo shfmt https://github.com/mvdan/sh/releases/download/v3.8.0/shfmt_v3.8.0_darwin_amd64
   # chmod +x shfmt
   # sudo mv shfmt /usr/local/bin/
   ```

8. **Lefthook**: Since you have installed Node.js/npm, you can install Lefthook
   globally:
   ```bash
   npm install -g lefthook
   ```

#### Ubuntu/Debian

```bash
# Add HashiCorp repo and install Terraform
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install terraform

# Install Python, Node.js, ShellCheck, shfmt, Black, and general build tools
sudo apt-get install -y python3 python3-pip nodejs npm shellcheck shfmt black

# Install Lefthook
curl -1sLf 'https://dl.cloudsmith.io/public/evilmartians/lefthook/setup.deb.sh' | sudo bash
sudo apt-get install lefthook
```

_(For Google Cloud SDK installation, please refer to the official
[Google Cloud SDK Installation Guide](https://cloud.google.com/sdk/docs/install).)_

### 2. Install Dependencies (using shared configs)

To keep your local environment synchronized with the Dev Container, install
dependencies from the shared configuration files under
`.devcontainer/dependencies/`:

#### Python Dependencies (Black & isort)

Run this command from the repository root:

```bash
pip install -r .devcontainer/dependencies/requirements.txt
```

#### Node.js Dependencies (Prettier & Plugins)

Run this command to install Prettier and its plugins using `npm install`:

```bash
cd .devcontainer/dependencies
npm install
```

Create a symbolic link in the repository root so Prettier and other tooling can
resolve plugins relative to the project root:

```bash
cd ../..
ln -s .devcontainer/dependencies/node_modules node_modules
```

To run Prettier globally from the command line, append the local binary path to
your PATH in your shell configuration (e.g. `~/.zshrc` or `~/.bashrc`):

```bash
export PATH="$PATH:$(pwd)/.devcontainer/dependencies/node_modules/.bin"
```

### 3. Initialize Git Hooks (Lefthook)

This repository uses [Lefthook](https://github.com/evilmartians/lefthook) to run
formatters and linters automatically on every commit. Once you have installed
Lefthook, run the following command in the repository root to enable the git
hooks:

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
