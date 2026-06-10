# Install Tailscale on the host running vxnode.
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up

# Expose the API publicly with a Tailscale Funnel (HTTPS auto-issued).
sudo tailscale funnel --bg 8744

# Tailscale prints the public hostname, e.g.
#   https://node1.tail-scale.ts.net
# Use that hostname when registering the node with vxcloud.