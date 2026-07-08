#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Configuration
PYTHON_VERSION="3.11.9"
NODE_VERSION="24"
INSTALL_DIR="${HOME}/.local/bin"

# Help message
usage() {
  cat << EOF
Usage: $0 [options]

Options:
  -h, --help      Show this help message
  --sys-deps      Attempt to install system dependencies (requires sudo/root on Linux)
EOF
  exit 0
}

INSTALL_SYS_DEPS=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
  -h | --help)
    usage
    ;;
  --sys-deps)
    INSTALL_SYS_DEPS=true
    shift
    ;;
  *)
    echo "Unknown option: $1"
    usage
    ;;
  esac
done

DEPS_DIR="${DEPS_DIR:-.devcontainer/dependencies}"

if [ ! -d "${DEPS_DIR}" ] && [ -d "/tmp/dependencies" ]; then
  DEPS_DIR="/tmp/dependencies"
fi

if [ ! -f "${DEPS_DIR}/requirements.txt" ]; then
  echo "Error: Cannot find dependencies directory. Please set DEPS_DIR or run from repo root."
  exit 1
fi

mkdir -p "${INSTALL_DIR}"

# Add local bin to PATH for this script session
export PATH="${INSTALL_DIR}:${PATH}"

# Detect OS
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

echo "Detected OS: ${OS}, Arch: ${ARCH}"

# Function to install system dependencies
install_system_deps() {
  if [ "${INSTALL_SYS_DEPS}" = false ]; then
    echo "Skipping system dependencies installation. Use --sys-deps to install them."
    return 0
  fi

  if [ "${OS}" = "linux" ]; then
    if [ -f /etc/debian_version ]; then
      echo "Debian-based system detected. Installing system dependencies..."
      local packages=(
        build-essential
        ca-certificates
        curl
        git
        libbz2-dev
        libc6
        libffi-dev
        liblzma-dev
        libncursesw5-dev
        libreadline-dev
        libsqlite3-dev
        libssl-dev
        libstdc++6
        libxml2-dev
        libxmlsec1-dev
        tk-dev
        unzip
        xz-utils
        zlib1g-dev
      )
      if [ "$(id -u)" -eq 0 ]; then
        apt-get update && apt-get install -y --no-install-recommends "${packages[@]}"
      elif command -v sudo > /dev/null; then
        sudo apt-get update && sudo apt-get install -y --no-install-recommends "${packages[@]}"
      else
        echo "Warning: Cannot install system dependencies (not root and no sudo)."
        echo "Please ensure you have build dependencies for Python installed."
      fi
    else
      echo "Warning: Unsupported Linux distribution. Please install build dependencies manually."
    fi
  elif [ "${OS}" = "darwin" ]; then
    echo "macOS detected. Checking Xcode Command Line Tools..."
    if ! xcode-select -p > /dev/null 2>&1; then
      echo "Xcode Command Line Tools not found. Please install them by running:"
      echo "  xcode-select --install"
      echo "And then re-run this script."
      exit 1
    fi
  fi
}

# Install pyenv and Python
install_python() {
  if [ ! -d "${HOME}/.pyenv" ]; then
    echo "Installing pyenv..."
    curl https://pyenv.run | bash
  else
    echo "pyenv already installed."
  fi

  export PYENV_ROOT="${HOME}/.pyenv"
  # shellcheck disable=SC2016
  [[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"
  eval "$(pyenv init -)"

  echo "Installing Python ${PYTHON_VERSION}..."
  if ! pyenv install --skip-existing "${PYTHON_VERSION}"; then
    echo "$(F)ailed to install Python ${PYTHON_VERSION}."
    return 1
  fi
  pyenv global "${PYTHON_VERSION}"
}

# Install fnm and Node
install_node() {
  if [ ! -d "${HOME}/.local/share/fnm" ]; then
    echo "Installing fnm..."
    curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "${HOME}/.local/share/fnm" --skip-shell
  else
    echo "fnm already installed."
  fi

  export PATH="${HOME}/.local/share/fnm:${PATH}"
  eval "$(fnm env --shell bash)"

  echo "Installing Node ${NODE_VERSION}..."
  fnm install "${NODE_VERSION}"
  fnm default "${NODE_VERSION}"
}

# Install tfswitch and Terraform
install_terraform() {
  if [ ! -f "${INSTALL_DIR}/tfswitch" ]; then
    echo "Installing tfswitch to ${INSTALL_DIR}..."
    curl -L https://raw.githubusercontent.com/warrensbox/terraform-switcher/master/install.sh | bash -s -- -b "${INSTALL_DIR}"
  else
    echo "tfswitch already installed."
  fi

  # Configure tfswitch to use local bin
  echo "bin = \"${INSTALL_DIR}/terraform\"" > "${HOME}/.tfswitch.toml"

  echo "Installing Terraform (latest or from constraint)..."
  # Run tfswitch to install terraform. It will use .tfswitch.toml config.
  # We try to install a default version to avoid interactive prompt if run non-interactively.
  # 1.5.7 is a safe default.
  "${INSTALL_DIR}/tfswitch" 1.5.7
}

# Install gcloud CLI
install_gcloud() {
  if [ ! -d "${HOME}/google-cloud-sdk" ]; then
    echo "Installing Google Cloud CLI..."
    local gcloud_tar=""
    if [ "${OS}" = "linux" ]; then
      if [ "${ARCH}" = "x86_64" ]; then
        gcloud_tar="google-cloud-cli-linux-x86_64.tar.gz"
      elif [ "${ARCH}" = "aarch64" ] || [ "${ARCH}" = "arm64" ]; then
        gcloud_tar="google-cloud-cli-linux-arm.tar.gz"
      fi
    elif [ "${OS}" = "darwin" ]; then
      if [ "${ARCH}" = "x86_64" ]; then
        gcloud_tar="google-cloud-cli-darwin-x86_64.tar.gz"
      elif [ "${ARCH}" = "arm64" ]; then
        gcloud_tar="google-cloud-cli-darwin-arm.tar.gz"
      fi
    fi

    if [ -n "${gcloud_tar}" ]; then
      curl -fsSL "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/${gcloud_tar}" -o "/tmp/${gcloud_tar}"
      tar -xf "/tmp/${gcloud_tar}" -C "${HOME}"
      rm "/tmp/${gcloud_tar}"
      "${HOME}/google-cloud-sdk/install.sh" --quiet --usage-reporting=false --path-update=false --bash-completion=false
    else
      echo "Warning: Unsupported platform for manual gcloud install: ${OS}_${ARCH}"
    fi
  else
    echo "Google Cloud CLI already installed."
  fi
}

# Install shellcheck and shfmt
install_linters() {
  echo "Installing shellcheck and shfmt..."

  # shfmt
  local shfmt_arch=""
  if [ "${ARCH}" = "x86_64" ]; then
    shfmt_arch="amd64"
  elif [ "${ARCH}" = "arm64" ] || [ "${ARCH}" = "aarch64" ]; then
    shfmt_arch="arm64"
  fi

  if [ -n "${shfmt_arch}" ]; then
    echo "Downloading shfmt..."
    curl -Lo "${INSTALL_DIR}/shfmt" "https://github.com/mvdan/sh/releases/download/v3.8.0/shfmt_v3.8.0_${OS}_${shfmt_arch}"
    chmod +x "${INSTALL_DIR}/shfmt"
  else
    echo "Warning: Unsupported arch for shfmt: ${ARCH}"
  fi

  # Install shellcheck
  local sc_arch=""
  if [ "${ARCH}" = "x86_64" ]; then
    sc_arch="x86_64"
  elif [ "${ARCH}" = "arm64" ] || [ "${ARCH}" = "aarch64" ]; then
    sc_arch="aarch64"
  fi

  if [ -n "${sc_arch}" ]; then
    echo "Downloading shellcheck..."
    local sc_os="${OS}"
    # The shellcheck binary releases use 'darwin' or 'linux'

    curl -Lo "/tmp/shellcheck.tar.xz" "https://github.com/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.${sc_os}.${sc_arch}.tar.xz"
    tar -xf "/tmp/shellcheck.tar.xz" -C "/tmp"
    mv "/tmp/shellcheck-v0.10.0/shellcheck" "${INSTALL_DIR}/"
    rm -rf "/tmp/shellcheck.tar.xz" "/tmp/shellcheck-v0.10.0"
  else
    echo "Warning: Unsupported arch for shellcheck: ${ARCH}"
  fi
}

install_dependencies() {
  echo "Installing Python dependencies..."
  local pip_bin
  pip_bin=$(pyenv which pip || echo "pip")
  "${pip_bin}" install --no-cache-dir -r "${DEPS_DIR}/requirements.txt"

  echo "Installing Node dependencies..."
  (
    # Set path for fnm in this subshell
    export PATH="${HOME}/.local/share/fnm:${PATH}"
    eval "$(fnm env --shell bash)"
    cd "${DEPS_DIR}"
    npm install --no-audit --no-fund

    # Create symlink only if we are running from a git repo and NOT in /tmp
    if [[ ${DEPS_DIR} != /*tmp* ]]; then
      cd ../..
      if [ ! -L node_modules ] && [ ! -d node_modules ]; then
        echo "Creating symlink for node_modules..."
        ln -s .devcontainer/dependencies/node_modules node_modules
      elif [ -L node_modules ]; then
        echo "node_modules symlink already exists."
      else
        echo "Warning: node_modules exists and is not a symlink. Skipping symlink creation."
      fi

      # Symlink lefthook to local bin for convenience
      if [ -f node_modules/.bin/lefthook ]; then
        echo "Linking lefthook to ${INSTALL_DIR}..."
        ln -sfn "$(pwd)/node_modules/.bin/lefthook" "${INSTALL_DIR}/lefthook"
      fi
    else
      echo "Detected /tmp build environment. Skipping symlink creation."
    fi
  )
}

# Main installation flow
install_system_deps
install_python
install_node
install_terraform
install_gcloud
install_linters
install_dependencies

echo "All tools installed successfully."
echo "Please add the following to your shell profile (~/.bashrc or ~/.zshrc) to enable them:"
echo "--------------------------------------------------"

# shellcheck disable=SC2016
{
  echo 'export PATH="${HOME}/.local/bin:${PATH}"'
  echo 'export PYENV_ROOT="${HOME}/.pyenv"'
  echo '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"'
  echo 'eval "$(pyenv init -)"'
  echo 'export PATH="${HOME}/.local/share/fnm:$PATH"'
  echo 'eval "$(fnm env --shell bash)" # or zsh'
  echo 'export PATH="${HOME}/google-cloud-sdk/bin:$PATH"'
  echo "--------------------------------------------------"
}
