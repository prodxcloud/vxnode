# Install cloudflared, then expose vxnode over HTTPS via a free Cloudflare Tunnel.
cloudflared tunnel login
cloudflared tunnel create vxnode

# Map your hostname to the local vxnode port
cloudflared tunnel route dns vxnode node1.vxcloud.io
cloudflared tunnel run --url http://localhost:8744 vxnode

# Cloudflare now serves https://node1.vxcloud.io with a managed TLS cert.