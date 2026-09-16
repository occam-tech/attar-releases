# Attar releases

Linux x86_64 requires glibc 2.39 or newer. Dev releases are previews; use `--channel dev` explicitly.

## Debian or Ubuntu

```sh
curl -fsSL https://occam-tech.github.io/attar-releases/release-key.asc | sudo tee /usr/share/keyrings/attar.asc >/dev/null
echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/attar.asc] https://github.com/occam-tech/attar-releases/releases/download/apt-dev/ ./' | sudo tee /etc/apt/sources.list.d/attar.list
sudo apt-get update && sudo apt-get install attar
```

## Other Linux x86_64

```sh
curl -fsSL https://occam-tech.github.io/attar-releases/install.sh -o install.sh
sh install.sh --channel dev
export PATH="$HOME/.local/bin:$PATH"
attar doctor
attar init my-app --template tsx
attar build my-app
```

## macOS 15+ Apple silicon

Requires macOS 15 or newer on Apple silicon and Xcode Command Line Tools (CLT). If needed, install CLT with `xcode-select --install`.

The Homebrew formula is published in the `occam-tech/attar` tap:

```sh
brew tap occam-tech/attar
brew install occam-tech/attar/attar
```
Release metadata is in `index.json` and is authenticated by `index.json.asc`.
