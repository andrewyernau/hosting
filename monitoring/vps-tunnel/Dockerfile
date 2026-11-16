FROM alpine:3.22
RUN apk add --no-cache openssh-client-default && adduser -D -u 1000 tunnel
USER tunnel
ENTRYPOINT ["ssh", "-N", "-F", "/dev/null", "-i", "/run/key", "-l", "metrics-tunnel", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "UserKnownHostsFile=/run/known_hosts", "-o", "StrictHostKeyChecking=yes", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "-L", "0.0.0.0:9100:127.0.0.1:9100", "-L", "0.0.0.0:9115:127.0.0.1:9115", "-L", "0.0.0.0:8405:127.0.0.1:8405", "143.20.32.134"]
