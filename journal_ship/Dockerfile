ARG BUILD_FROM
FROM $BUILD_FROM

# Debian rather than Alpine because the host journal is read with journalctl, which needs
# systemd's libraries; trixie's systemd matches the journal format HAOS writes. Nothing from
# systemd runs here, only the journalctl binary is used. python3 is the shipper itself
# (standard library only: no pip, nothing to audit beyond this directory).
RUN apt-get update \
    && apt-get install -y --no-install-recommends systemd python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && date -u +%Y-%m-%dT%H:%M:%SZ > /etc/local-build-date

COPY rootfs /
RUN chmod +x /run.sh /usr/local/bin/journal_ship.py

WORKDIR /
CMD ["/run.sh"]
