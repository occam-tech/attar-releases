# Attar releases

Attar releases provide the CLI, AOT compiler, SDK, starter templates, and
`attar doctor` for external development.

Development releases are previews. The archive installer defaults to the
development channel; pass `--channel stable` explicitly when you want stable.
A stable request fails if that channel has no release and never falls back to
development.

## Linux x86_64

The Linux distribution requires glibc 2.39 or newer. Debian and
Ubuntu users can install from the signed APT endpoint at
https://github.com/occam-tech/attar-releases/releases/download/apt-dev:

```sh
curl -fsSL https://occam-tech.github.io/attar-releases/release-key.asc | sudo tee /usr/share/keyrings/attar.asc >/dev/null
echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/attar.asc] https://github.com/occam-tech/attar-releases/releases/download/apt-dev ./' | sudo tee /etc/apt/sources.list.d/attar.list
sudo apt-get update
sudo apt-get install attar
```

On Arch and other glibc based Linux distributions, use the archive installer
at https://occam-tech.github.io/attar-releases/install.sh. It checks for Python 3.11+, `gpg`, `gpgv`, and `readelf`
from `binutils` before downloading, then verifies the configured glibc floor.

```sh
curl -fsSL https://occam-tech.github.io/attar-releases/install.sh -o install.sh
sh install.sh --channel dev
export PATH="$HOME/.local/bin:$PATH"
attar doctor
attar init my-app --template tsx
attar build my-app
```

## macOS ARM64

The macOS distribution supports Apple silicon on macOS 15.0 or
newer and requires Xcode Command Line Tools. The Homebrew formula is provided
by the configured formula below. Homebrew accepts the fully qualified formula
name directly, so no tap or trust setup is required:

```sh
brew install occam-tech/attar/attar
```

Attar also needs an installed Apple SDK compatible with the toolchain bundled
in this release. Without an explicit override, the build probes installed
SDKs from newest to oldest and selects the first compatible SDK. To make the
selection authoritative, pass `--macos-sdk PATH`; a rejected explicit path
does not fall back to another SDK. If no compatible SDK is installed, install
one through Xcode or the Command Line Tools, then retry.

```sh
attar doctor
attar init my-app --template tsx
attar build my-app
```

Release metadata is in `index.json` and is authenticated by `index.json.asc`.
