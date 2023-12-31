#!/bin/bash -e

cd "$GITHUB_ACTION_PATH"
kernel="$(uname -s)"

case "$kernel" in
Linux)
  sudo apt-get update
  sudo apt-get install -y tmux

  cloudflared_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"
  echo "Downloading \`cloudflared\` from <$cloudflared_url>..."
  curl --location --silent --output cloudflared "$cloudflared_url"
  ;;
Darwin)
  brew install tmux

  cloudflared_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-amd64.tgz"
  echo "Downloading \`cloudflared\` from <$cloudflared_url>..."
  curl --location --silent --output cloudflared.tgz "$cloudflared_url"
  tar -xzf cloudflared.tgz
  ;;
esac
chmod +x cloudflared

curl -s "https://api.github.com/users/$GITHUB_ACTOR/keys"
curl -s "https://api.github.com/users/$GITHUB_ACTOR/keys" | jq -r '.[].key' > authorized_keys

if grep -q . authorized_keys; then
    echo "Configured SSH key(s) for user: $GITHUB_ACTOR"
else
    echo "No SSH key found for user: $GITHUB_ACTOR"
    echo "Setting SSH password..."

    #
    # This command could be "beautifully" lazy like the commented line below,
    # but for some reason on GitHub Actions specifically (and nowhere else I
    # could find) it logs the following warnings:
    #
    #     tr: write error: Broken pipe
    #     tr: write error
    #     base64: write error: Broken pipe
    #     base64: write error
    #
    # Even though it still succeeds and behaves properly, I'd rather not have
    # those warnings show up, so I use `head` twice, getting 16 bytes off
    # `/dev/urandom`, Base64-encoding it (which should give us 25 characters),
    # and we drop all the nonalphanumeric ones and trim it to 16 chars.
    #
    password=$(head -c 16 /dev/urandom | base64 | tr -cd '[:alnum:]' | head -c 16)
    # password=$(base64 < /dev/urandom | tr -cd '[:alnum:]' | head -c16)

    (echo "$password"; echo "$password") | sudo passwd "$USER"
fi

# `-q` is to make it quiet, `-N ''` is for empty passphrase
echo 'Creating SSH server key...'
ssh-keygen -q -f ssh_host_rsa_key -N ''
echo "$fingerprint"

echo 'Creating SSH server config...'
sed "s,\$PWD,$PWD,;s,\$USER,$USER," sshd_config.template > sshd_config

echo 'Starting SSH server...'
/usr/sbin/sshd -f sshd_config -D &
sshd_pid=$!

echo 'Starting tmux session...'
(cd "$GITHUB_WORKSPACE" && tmux new-session -d -s debug)

# Use `sed -u` (unbuffered) otherwise logs don't show up in the UI
echo 'Starting Cloudflare tunnel...'
./cloudflared tunnel --no-autoupdate --url tcp://localhost:2222 2>&1 | tee cloudflared.log | sed -u 's/^/cloudflared: /' &
cloudflared_pid=$!

#
# Tail `cloudflared.log` to find the part where they share the relay
# hostname.
#
# Shell substitution `<()` required to prevent the pipeline from hanging
# even after it finds a first match. See <https://stackoverflow.com/a/45327054>.
#
# Requires GNU Bash.
#
url=$(head -1 <(tail -f cloudflared.log | grep --line-buffered -o 'https://.*\.trycloudflare.com'))

# POSIX-compatible but just hangs
# url=$(tail -f cloudflared.log | grep --line-buffered -o 'https://.*\.trycloudflare.com' | head -1)

# POSIX-compatible using simple polling instead
# url=$(while ! grep -o 'https://.*\.trycloudflare.com' cloudflared.log; do sleep 1; done)

# Ignore the `user@host` part at the end of the public key
public_key=$(cut -d' ' -f1,2 < ssh_host_rsa_key.pub)

# Echo spaces on empty lines because if we just echo a newline, GitHub will eat it
echo '    '
echo '    '
echo '    '
echo '    '
echo 'Run the following command to connect:'
echo '    '
echo "    ssh-keygen -R action-sshd-cloudflared && echo 'action-sshd-cloudflared $public_key' >> ~/.ssh/known_hosts && ssh -o ProxyCommand='cloudflared access tcp --hostname $url' runner@action-sshd-cloudflared"

#
# Unlike Upterm that runs a custom SSH server to accept passwords in the
# username field with the `:password` syntax, standard `sshd` doesn't
# accept that, so we need to paste the password like mere mortals.
#
if [ -n "$password" ]; then
    echo '    '
    echo "    # Password: $password"
fi

#
# You might notice we use `action-sshd-cloudflared` as a SSH host to connect.
# This is abritrary and we could put anything here, because of the
# `ProxyCommand` option later, the host is ignored and we directly go through
# the tunnel exposed by `cloudflared`. But for the `ssh` command to be valid,
# we still need to give it a host.
#
echo '    '
echo "What the one-liner does:"
echo '    '
echo '    # Remove old SSH server public key for `action-sshd-cloudflared`'
echo "    ssh-keygen -R action-sshd-cloudflared"
echo '    '
echo '    # Trust the public key for this session'
echo "    echo 'action-sshd-cloudflared $public_key' >> ~/.ssh/known_hosts"
echo '    '
echo '    # Connect using `cloudflared` as a transport (SSH is end-to-end encrpted over this tunnel)'
echo "    ssh -o ProxyCommand='cloudflared access tcp --hostname $url' runner@action-sshd-cloudflared"
echo '    '
echo "    # Alternative if you don't want to verify the host key"
echo "    ssh -o ProxyCommand='cloudflared access tcp --hostname $url' -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=accept-new runner@action-sshd-cloudflared"
echo '    '
echo '    '
echo '    '
echo '    '

#
# The `channel` argument is not used but needs to be passed.
#
# `wait-for` will hang until we call `tmux wait-for -S channel` (which we
# don't) but it'll also exit when all tmux sessions are over, which is
# fine with us!
#
tmux wait-for channel

echo 'Session ended'

kill "$cloudflared_pid"
kill "$sshd_pid"
