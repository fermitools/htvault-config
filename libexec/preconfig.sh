#!/bin/bash
# Create vault.hcl from template

PARAMS=/etc/htvault-config/config.d/parameters.sh
if [ ! -f $PARAMS ]; then
    echo "$PARAMS missing" >&2
    exit 1
fi
. $PARAMS

if [ -n "$CLUSTERFQDN" ]; then
    TMPLTYPE=raft
else
    TMPLTYPE=single
fi

cat /usr/libexec/htvault-config/vault.common.template \
    /usr/libexec/htvault-config/vault.$TMPLTYPE.template \
    | sed -e "s,<myfqdn>,$MYFQDN," \
        -e "s,<clusterfqdn>,$CLUSTERFQDN," \
        -e "s,<peer1fqdn>,$PEER1FQDN," \
        -e "s,<peer2fqdn>,$PEER2FQDN," \
        >/var/lib/htvault-config/vault.hcl
