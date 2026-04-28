ARG BASE_IMAGE=fedora:latest
FROM $BASE_IMAGE

# Pin the agent user/group to a high, stable UID/GID (24368) so it will
# not collide with typical host UIDs (1000-range) that keep-id remaps.
# Later steps mix name-based (`chown agent:agent`, sudoers `__USER__`
# substitution) and numeric (`USER 24368`) references — they only stay
# consistent if the name `agent` and the numeric UID 24368 point at the
# same account. If a pre-existing `agent` exists at a different UID,
# fail fast: silently skipping creation would leave /var/workdir owned
# by the wrong account and the sudoers rule applied to a non-runtime
# user, both of which would surface much later as confusing failures.
RUN set -e; \
    if id agent >/dev/null 2>&1; then \
        _uid=$(id -u agent); _gid=$(id -g agent); \
        if [ "$_uid" != "24368" ] || [ "$_gid" != "24368" ]; then \
            echo "Containerfile: pre-existing 'agent' user has uid=$_uid gid=$_gid; need 24368/24368 to stay consistent with chown/sudoers/USER directives" >&2; \
            exit 1; \
        fi; \
    else \
        groupadd -g 24368 agent && useradd -m -u 24368 -g 24368 agent; \
    fi; \
    dnf install -y sudo && dnf clean all
RUN mkdir -p /var/workdir \
             /usr/local/lib/crate \
             /usr/local/libexec/crate \
             /usr/local/etc/crate && \
    chown -R agent:agent /var/workdir && \
    chmod 0755 /usr/local/etc/crate
COPY lib/log.sh /usr/local/lib/crate/log.sh
COPY bin/enable-dnf.sh /usr/local/lib/crate/enable-dnf
COPY bin/setup-tools.sh /usr/local/libexec/crate/setup-tools.sh
COPY config/sudoers-enable-dnf.tmpl /tmp/sudoers-enable-dnf.tmpl
RUN sed 's|__USER__|agent|g; s|\r$||' /tmp/sudoers-enable-dnf.tmpl > /etc/sudoers.d/agent-enable-dnf && \
    rm /tmp/sudoers-enable-dnf.tmpl && \
    sed -i 's|\r$||' /usr/local/lib/crate/log.sh \
                     /usr/local/lib/crate/enable-dnf \
                     /usr/local/libexec/crate/setup-tools.sh && \
    chmod 0755 /usr/local/lib/crate/enable-dnf /usr/local/libexec/crate/setup-tools.sh && \
    chmod 0644 /usr/local/lib/crate/log.sh && \
    chmod 0440 /etc/sudoers.d/agent-enable-dnf && \
    visudo -cf /etc/sudoers.d/agent-enable-dnf

ENV PATH=/home/agent/.local/bin:$PATH
USER 24368
WORKDIR /var/workdir
ENTRYPOINT ["/usr/local/libexec/crate/setup-tools.sh", "--exec", "/tmp/base.tar.xz", "/tmp/tool.tar.xz", "/tmp/agent.tar.xz"]
