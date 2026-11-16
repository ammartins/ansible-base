# W7.3 SSH hardening (security-ssh)
Adds MaxAuthTries 3, LoginGraceTime 60, login banner, and subtractive
MACs/KexAlgorithms (drops hmac-sha1*, umac-64*, dh-group14/gex). TCP forwarding
stays enabled (tooling uses ssh -L). Applied live 2026-11-16.
Rollback per host: restore /root/50-hardening.conf.pre-w73.<ts> to
/etc/ssh/sshd_config.d/50-hardening.conf, `sshd -t && systemctl reload ssh`.
