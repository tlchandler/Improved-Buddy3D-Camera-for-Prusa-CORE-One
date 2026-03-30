#!/bin/sh
# Buddy3D Camera Web Settings Server
# Uses BusyBox inetd to handle HTTP connections

WEBDIR=/mnt/sdcard/web

# Create inetd config for port 80
cat > /tmp/buddy_inetd.conf << EOF
80 stream tcp nowait root /bin/sh sh ${WEBDIR}/handler.sh
EOF

# Start inetd (stays in foreground with -f, but we want background)
inetd /tmp/buddy_inetd.conf
