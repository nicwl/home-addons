ARG BUILD_FROM
FROM $BUILD_FROM

# Debian rather than Alpine because the host journal is read with journalctl, which needs
# systemd's libraries; trixie's systemd matches the journal format HAOS writes. Nothing from
# systemd runs here, only the journalctl binary is used. python3 is the shipper itself
# (standard library only: no pip, nothing to audit beyond this directory).
# Cache key for the package layer: Docker re-runs the apt step whenever trixie-security's index changes,
# so a rebuild always carries the current ca-certificates and systemd rather than a cached layer.
ADD https://deb.debian.org/debian-security/dists/trixie-security/InRelease /tmp/security-inrelease
RUN apt-get update \
    && apt-get install -y --no-install-recommends systemd python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && date -u +%Y-%m-%dT%H:%M:%SZ > /etc/local-build-date \
    && rm -f /tmp/security-inrelease

COPY rootfs /
RUN chmod +x /run.sh /usr/local/bin/journal_ship.py

WORKDIR /
CMD ["/run.sh"]
