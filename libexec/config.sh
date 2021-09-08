#!/bin/bash
#
# Note to modifier: watch out for any secrets showing up on the command line,
#  because those can be seen in a 'ps'
#
# This source file is Copyright (c) 2021, FERMI NATIONAL
#   ACCELERATOR LABORATORY.  All rights reserved.

usage()
{
    echo 'Usage: config.sh [-nowait]'
    echo "The -nowait option skips waiting for peers in multi-server config"
    exit 1
} >&2


NOWAIT=false
if [ "$1" = "-nowait" ]; then
    NOWAIT=true
    shift
fi

if [ $# != 0 ]; then
    usage
fi

echo
echo "Starting vault configuration at `date`"

LIBEXEC=/usr/libexec/htvault-config
VARLIB=/var/lib/htvault-config
cd $VARLIB

if $LIBEXEC/parseconfig.py /etc/htvault-config/config.d > config.json.new; then
    if [ -f config.json ]; then
        mv config.json config.json.old
    fi
    mv config.json.new config.json
    if $LIBEXEC/jsontobash.py <config.json >config.bash.new; then
        if [ -f config.bash ]; then
            sed 's/^/_old/' config.bash >config.bash.old
            rm -f config.bash
        fi
    else
        echo "Failure converting config.json to config.bash" >&2
        exit 1
    fi
else
    echo "Failure converting /etc/htvault-config/config.d/*.yaml to config.json" >&2
    exit 1
fi

if [ -f config.bash.old ]; then
    . ./config.bash.old
fi
. ./config.bash.new

ISMASTER=true
MYNAME="${_cluster_myname:-`uname -n`}"
if [ -n "$_cluster_master" ] && [ "$_cluster_master" != "$MYNAME" ]; then
    ISMASTER=false
fi
SERVICENAME="${_cluster_name:-$MYNAME}"
old_SERVICENAME="${_old_cluster_name:-${_old_cluster_myname:-`uname -n`}}"
export VAULT_ADDR=http://127.0.0.1:8202

if [ -n "$_cluster_master" ]; then
    vault operator raft join -format=json $VAULT_ADDR | jq -r keys[0]
fi

if [ ! -f vaultseal.txt ] && $ISMASTER; then
    echo "Initializing database"
    if ! vault operator init -key-shares=1 -key-threshold=1 -format=json >keys.json; then
        echo "Failed to initialize vault DB" >&2
        rm -f keys.json
        exit 2
    fi
    jq -r ".unseal_keys_b64[0]" keys.json >vaultseal.txt
    jq -r ".root_token" keys.json >~/.vault-token
    chmod 600 vaultseal.txt ~/.vault-token
    if [ ! -s vaultseal.txt ] || [ ! -s ~/.vault-token ]; then
        echo "Failed to get unseal key or root vault token" >&2
        exit 2
    fi
fi

if vault status >/dev/null; then
    echo "vault is unsealed"
else
    echo "vault status failed, attempting to unseal"
    # Try multiple times because it can take a while to initialize a new
    #   raft storage from peers.
    TRY=0
    MAX=20
    while [ "$TRY" -lt "$MAX" ]; do
        # "vault operator unseal" has no way to hide secret from command line
        #  so use API.
        OUT=$(curl -sS -X PUT -d @- $VAULT_ADDR/v1/sys/unseal <<EOF
            { "key" : "$(< vaultseal.txt)" }
EOF
        )
        if [ "$(echo "$OUT"|jq .sealed)" = "false" ]; then
	    break
	fi
	let TRY+=1
	echo "Unseal try $TRY failed"
        ERR="$(echo "$OUT"|jq .errors)"
        if [ -n "$ERR" ] && [ "$ERR" != null ]; then
            echo "$ERR"
        fi
	sleep 1
    done
    if [ "$TRY" -eq "$MAX" ]; then
	echo "Giving up"
	exit 1
    fi
fi

if ! $NOWAIT && [ "`vault status -format=json|jq -r .storage_type`" = "raft" ]; then
    TRY=0
    MAX=20
    while [ "$TRY" -lt "$MAX" ]; do
	if vault operator raft list-peers; then
	    break
	fi
	let TRY+=1
	echo "Waiting for peers, try $TRY"
	sleep 1
    done
    if [ "$TRY" -eq "$MAX" ]; then
	echo "Giving up"
	exit 1
    fi
fi

# successfully started, save the new configuration
mv config.bash.new config.bash

if ! $ISMASTER; then
    echo "Completed vault configuration at `date`"
    exit 0
fi

if [ -n "$_old_cluster_master" ] && [ "$_cluster_master" != "$_old_cluster_master" ]; then
    echo "Removing old master $_old_cluster_master"
    vault operator raft remove-peer "$_old_cluster_master"
fi
if [ -n "$_old_cluster_peer1" ] && [ "$_cluster_peer1" != "$_old_cluster_peer1" ]; then
    echo "Removing old peer1 $_old_cluster_peer1"
    vault operator raft remove-peer "$_old_cluster_peer1"
fi
if [ -n "$_old_cluster_peer2" ] && [ "$_cluster_peer2" != "$_old_cluster_peer2" ]; then
    echo "Removing old peer2 $_old_cluster_peer2"
    vault operator raft remove-peer "$_old_cluster_peer2"
fi

ENBLEDMODS=""
updateenabledmods()
{
    ENABLEDMODS="`
        (vault auth list -format=json|jq keys
         vault secrets list -format=json|jq keys)| \
          egrep "(kerberos|oidc|oauth)"| \
           sed 's/"//g;s-/,--;s-[^ /]*/--'`"
    # remove newlines
    ENABLEDMODS="`echo $ENABLEDMODS`"
}
updateenabledmods

modenabled()
{
    case " $ENABLEDMODS " in
	*" $1 "*)
            return
            ;;
    esac
    return 1
}

loadplugin()
{
    typeset PLUGIN="vault-plugin-$1.sh"
    typeset SHA="`sha256sum $LIBEXEC/plugins/$PLUGIN|awk '{print $1}'`"
    typeset CATPATH="sys/plugins/catalog/$2"
    if [ "`vault read $CATPATH -format=json 2>/dev/null|jq -r .data.sha256`" != "$SHA" ]; then
	echo "Defining plugin $1"
	vault write $CATPATH sha256=$SHA command=$PLUGIN
    fi
}

AUDITLOG=/var/log/htvault-config/auditlog
if [ "$(vault audit list -format=json|jq -r .\"file/\".options.file_path)" != $AUDITLOG ]; then
    echo "Enabling audit log at $AUDITLOG"
    vault audit enable file file_path=$AUDITLOG log_raw=true
fi

mkdir -p policies
POLICIES=""
DELETEDPOLICIES=""
# COMPATPOLICIES are temporary for backward compatibility
COMPATPOLICIES=""
ISFIRST=true
OLDFIRSTKERBNAME=""
POLICYTYPES="oidc"
if [ "$_old_kerberos" != "$_kerberos" ]; then
    # The kerberos list changed
    # This is complicated because for htgettoken <= 1.2 the first kerberos
    #   service is just called "kerberos" instead of "kerberos-$KERBNAME"
    #   and the service that is first can change.  For htgettoken >= 1.3
    #   the first kerberos listed still needs to be known but only because
    #   it is the one that uses the default kerberos keytab and applies to
    #   any issuer names that don't match $KERBNAME.
    KERBNAMEDSERVICES=""
    for KERBNAME in $_kerberos; do
        if $ISFIRST; then
            ISFIRST=false
        else
            KERBNAMEDSERVICES="$KERBNAMEDSERVICES $KERBNAME"
        fi
    done
    ISFIRST=true
    for KERBNAME in $_old_kerberos; do
        if $ISFIRST; then
            ISFIRST=false
            OLDFIRSTKERBNAME="$KERBNAME"
            if [ -z "$_kerberos" ]; then
                # No kerberos any more
                echo "Disabling kerberos"
                vault auth disable kerberos
                updateenabledmods
            fi
        elif ! [[ " $KERBNAMEDSERVICES " == *" $KERBNAME "* ]]; then
            KERBSUFFIX="-$KERBNAME"
            echo "Disabling kerberos$KERBSUFFIX"
            vault auth disable kerberos$KERBSUFFIX
            updateenabledmods
        fi
        if ! [[ " $_kerberos " == *" $KERBNAME "* ]]; then
            DELETEDPOLICIES="$DELETEDPOLICIES kerberos${KERBNAME}"
        fi
    done
else
    for KERBNAME in $_old_kerberos; do
        OLDFIRSTKERBNAME="$KERBNAME"
        break
    done
fi
FIRSTKERBNAME=""
OTHERKERBNAMES=""
ISFIRST=true
for KERBNAME in $_kerberos; do
    if $ISFIRST; then
        ISFIRST=false
        KERBSUFFIX=""
    else
        KERBSUFFIX="-$KERBNAME"
    fi
    KEYTAB=/etc/krb5$KERBSUFFIX.keytab
    if [ ! -f $KEYTAB ]; then
        echo "$KEYTAB not found, skipping kerberos$KERBSUFFIX"
        continue
    fi
    if [ -z "$FIRSTKERBNAME$OTHERKERBNAMES" ]; then
        POLICYTYPES="$POLICYTYPES kerberos"
    fi
    if [ -z "$KERBSUFFIX" ]; then
        FIRSTKERBNAME="$KERBNAME"
    else
        OTHERKERBNAMES="$OTHERKERBNAMES $KERBNAME"
    fi
    COMPATPOLICIES="$COMPATPOLICIES kerberos$KERBNAME"
    CHANGED=false
    if ! modenabled kerberos$KERBSUFFIX; then
        CHANGED=true
        echo "Enabling kerberos$KERBSUFFIX"
        vault auth enable -path=kerberos$KERBSUFFIX \
            -passthrough-request-headers=Authorization \
            -allowed-response-headers=www-authenticate kerberos
    elif [ -z "$KERBSUFFIX" ] && [ "$OLDFIRSTKERBNAME" != "$KERBNAME" ]; then 
        # first kerberos service name changed
        CHANGED=true
    elif [ ! -f config.json.old ] || [ $KEYTAB -nt config.json.old ]; then
        echo "$KEYTAB changed since last configuration"
        CHANGED=true
    fi
    for VAR in ldapattr ldapdn ldapurl; do
        eval $VAR=\"\$_kerberos_${KERBNAME//-/_}_$VAR\"
        eval old_$VAR=\"\$_old_kerberos_${KERBNAME//-/_}_$VAR\"
        if eval [ \"\$$VAR\" != \"\$old_$VAR\" ]; then
            CHANGED=true
        fi
    done

    POLICYNAME=kerberos${KERBNAME}
    if $CHANGED || [ ! -f policies/$POLICYNAME.hcl ]; then
        echo "Configuring kerberos$KERBSUFFIX"
        base64 $KEYTAB >krb5.keytab.base64
        vault write auth/kerberos$KERBSUFFIX/config \
            keytab=@$VARLIB/krb5.keytab.base64 \
            service_account="host/$SERVICENAME"
        rm -f krb5.keytab.base64

        vault write auth/kerberos$KERBSUFFIX/config/ldap \
            url="$ldapurl" \
            userdn="$ldapdn" \
            userattr="$ldapattr" \
            token_policies="$POLICYNAME,tokencreate"
    fi
done

loadplugin secrets-oauthapp secret/oauth
loadplugin auth-jwt auth/oidc
updateenabledmods
if ! modenabled oauth; then
    OAUTHENABLED=false
    vault secrets enable secret/oauth
else
    OAUTHENABLED=true
fi
# disable modules that can be enabled during the first initialization
if modenabled oauthapp; then
    vault secrets disable oauthapp
fi
if modenabled oidc; then
    vault auth disable oidc
fi

disable_refresh_checks()
{
    if [ "`vault read $1/config -format=json 2>/dev/null|jq .data.tune_refresh_check_interval_seconds`" != 0 ]; then
        echo "Disabling refresh checks on $1"
        vault write $1/config tune_refresh_check_interval_seconds=0 
    fi
}
disable_refresh_checks secret/oauth

for POLICY in $COMPATPOLICIES; do
    echo "/* Generated from ${POLICY}policy.template */" >policies/${POLICY}.hcl.new
done

if [ "$_old_issuers" != "$_issuers" ]; then
    # The issuers list changed
    for ISSUER in $_old_issuers; do
        if ! [[ " $_issuers " == *" $ISSUER "* ]]; then
            echo "Disabling oidc-$ISSUER and secret/oauth-$ISSUER"
            vault auth disable oidc-$ISSUER
            vault secrets disable secret/oauth-$ISSUER
            updateenabledmods
            vault delete oauth/servers/$ISSUER
        fi
    done
fi
CURRENTKERBNAME=""
KERBCONFIGCHANGED=false
for ISSUER in $_issuers; do 
    VPATH=oidc-$ISSUER
    REDIRECT_URIS="https://$SERVICENAME:8200/v1/auth/$VPATH/oidc/callback"

    for VAR in clientid secret url roles callbackmode credclaim; do
        eval $VAR=\"\$_issuers_${ISSUER//-/_}_$VAR\"
        eval old_$VAR=\"\$_old_issuers_${ISSUER//-/_}_$VAR\"
    done

    if modenabled $VPATH; then
        ENABLED=true
    else
        ENABLED=false
        echo "Enabling $VPATH"
        vault auth enable -path=$VPATH oidc
    fi

    CHANGED=false
    if $ENABLED; then
        for VAR in url clientid secret; do
            if eval [ \"\$$VAR\" != \"\$old_$VAR\" ]; then
                CHANGED=true
                break
            fi
        done
    fi

    VPATH=auth/$VPATH
    if ! $ENABLED || $CHANGED; then
        echo "Configuring $VPATH"
        # use here doc and json input to avoid secrets on command line
        vault write $VPATH/config - \
            default_role=default \
            oidc_discovery_url="$url" \
            <<EOF
            {
                "oidc_client_id": "$clientid",
                "oidc_client_secret": "$secret"
            }
EOF
    fi

    CHANGED=false
    if $ENABLED; then
        if [ "$old_roles" != "$roles" ]; then
            # The roles list changed
            for ROLE in $old_roles; do
                if ! [[ " $roles " == *" $ROLE "* ]]; then
                    echo "Deleting $VPATH role $ROLE"
                    vault delete $VPATH/role/$ROLE
                    DELETEDPOLICIES="$DELETEDPOLICIES oidc${ISSUER}_${ROLE}"
                    if [ -n "$_old_kerberos" ]; then
                        DELETEDPOLICIES="$DELETEDPOLICIES kerberos${ISSUER}_${ROLE}"
                    fi
                fi
            done
        fi
        for VAR in credclaim callbackmode SERVICENAME; do
            if eval [ \"\$$VAR\" != \"\$old_$VAR\" ]; then
                CHANGED=true
                break
            fi
        done
    fi

    if [ -n "$FIRSTKERBNAME$OTHERKERBNAMES" ]; then
        if [[ " $OTHERKERBNAMES " == *" $ISSUER "* ]]; then
            KERBNAME="$ISSUER"
            KEYTAB=/etc/krb5-$ISSUER.keytab
        else
            KERBNAME="$FIRSTKERBNAME"
            KEYTAB=/etc/krb5.keytab
        fi
        if [ "$KERBNAME" != "$CURRENTKERBNAME" ]; then
            CURRENTKERBNAME="$KERBNAME"
            KERBCONFIGCHANGED=false
            if [ ! -f config.json.old ] || [ $KEYTAB -nt config.json.old ]; then
                echo "$KEYTAB changed since last configuration"
                KERBCONFIGCHANGED=true
            fi
            for VAR in ldapattr ldapdn ldapurl; do
                eval $VAR=\"\$_kerberos_${KERBNAME//-/_}_$VAR\"
                eval old_$VAR=\"\$_old_kerberos_${KERBNAME//-/_}_$VAR\"
                if eval [ \"\$$VAR\" != \"\$old_$VAR\" ]; then
                    KERBCONFIGCHANGED=true
                fi
            done
        fi
    fi

    for ROLE in $roles; do
        eval scopes=\"\$_issuers_${ISSUER//-/_}_roles_${ROLE//-/_}_scopes\"
        eval old_scopes=\"\$_old_issuers_${ISSUER//-/_}_roles_${ROLE//-/_}_scopes\"
        POLICYNAME=oidc${ISSUER}_${ROLE}
        if ! $ENABLED || $CHANGED || [ "$scopes" != "$old_scopes" ] || [ ! -f policies/${POLICYNAME}.hcl ]; then
            # use some json input in order to have nested parameters
            echo "Configuring $VPATH role $ROLE with scopes $scopes"
            vault write $VPATH/role/$ROLE - \
                role_type="oidc" \
                user_claim="$credclaim" \
                groups_claim="" \
                oidc_scopes="$scopes" \
                token_no_default_policy=true \
                policies=${POLICYNAME},tokencreate \
                callback_mode="${callbackmode:-device}" \
                poll_interval=3 \
                allowed_redirect_uris="$REDIRECT_URIS" \
                verbose_oidc_logging=true \
                <<EOF
                {
                    "claim_mappings": { "$credclaim" : "credkey" },
                    "oauth2_metadata": ["refresh_token"]
                }
EOF
        fi

        if [ -n "$FIRSTKERBNAME$OTHERKERBNAMES" ]; then
            KERBCHANGED=$KERBCONFIGCHANGED
            KERBSERVICE=kerberos-${ISSUER}_${ROLE}
            if ! modenabled $KERBSERVICE; then
                KERBCHANGED=true
                echo "Enabling $KERBERVICE"
                vault auth enable -path=$KERBSERVICE \
                    -passthrough-request-headers=Authorization \
                    -allowed-response-headers=www-authenticate kerberos
            fi

            POLICYNAME=kerberos${ISSUER}_${ROLE}
            if $KERBCHANGED || [ ! -f policies/$POLICYNAME.hcl ]; then
                echo "Configuring $KERBSERVICE"
                base64 $KEYTAB >krb5.keytab.base64
                vault write auth/$KERBSERVICE/config \
                    keytab=@$VARLIB/krb5.keytab.base64 \
                    service_account="host/$SERVICENAME"
                rm -f krb5.keytab.base64

                vault write auth/$KERBSERVICE/config/ldap \
                    url="$ldapurl" \
                    userdn="$ldapdn" \
                    userattr="$ldapattr" \
                    token_no_default_policy=true \
                    token_policies="$POLICYNAME,tokencreate"
            fi
        fi

        for POLICYTYPE in $POLICYTYPES; do
            if [ "$POLICYTYPE" = kerberos ]; then
                POLICYISSUER="${POLICYTYPE}-${ISSUER}_${ROLE}"
            else
                POLICYISSUER="${POLICYTYPE}-${ISSUER}"
            fi
            POLICYNAME="${POLICYTYPE}${ISSUER}_${ROLE}"
            POLICIES="$POLICIES ${POLICYNAME}"
            ACCESSOR="`vault read sys/auth -format=json|jq -r '.data."'$POLICYISSUER'/".accessor'`"
            sed -e "s,<issuer>,$ISSUER," -e "s/<${POLICYTYPE}>/$ACCESSOR/" -e "s/@<domain>/$policydomain/" -e "s/<role>/$ROLE/" $LIBEXEC/${POLICYTYPE}policy.template >>policies/${POLICYNAME}.hcl.new
        done
    done

    CHANGED=false
    if $ENABLED; then
        for VAR in url clientid; do
            if eval [ \"\$$VAR\" != \"\$old_$VAR\" ]; then
                CHANGED=true
                # server or clientid changed, disable the module to
                #  clear out all old secrets
                echo "Disabling secret/oauth-$ISSUER"
                vault secrets disable secret/oauth-$ISSUER
                updateenabledmods
                vault delete secret/oauth/servers/$ISSUER
                break
            fi
        done
        for VAR in secret; do
            if eval [ \"\$$VAR\" != \"\$old_$VAR\" ]; then
                CHANGED=true
                break
            fi
        done
    fi

    VPATH=secret/oauth-$ISSUER
    disable_refresh_checks $VPATH
    if ! $ENABLED || $CHANGED; then
        echo "Configuring $VPATH"
        if ! modenabled oauth-$ISSUER; then
            vault secrets enable -path=$VPATH oauthapp
        fi

        vault write $VPATH/servers/legacy - \
            provider="oidc" \
            provider_options="issuer_url=$url" \
            <<EOF
            {
                "client_id": "$clientid",
                "client_secret": "$secret"
            }
EOF
    fi

    if ! $ENABLED || ! $OAUTHENABLED || $CHANGED; then
        SPATH=secret/oauth/servers/$ISSUER
        echo "Configuring $SPATH"
        vault write $SPATH - \
            provider="oidc" \
            provider_options="issuer_url=$url" \
            tune_refresh_check_interval_seconds=0 \
            <<EOF
            {
                "client_id": "$clientid",
                "client_secret": "$secret"
            }
EOF
    fi

    ISFIRST=true
    for POLICY in $COMPATPOLICIES; do
        KERBNAME=${POLICY/kerberos/}
        if $ISFIRST; then
            ISFIRST=false
            KERBSUFFIX=""
        else
            KERBSUFFIX="-$KERBNAME"
        fi
        eval policydomain=\"\$_kerberos_${KERBNAME//-/_}_policydomain\"
        TEMPLATEPOLICY=kerberos
        POLICYISSUER=kerberos$KERBSUFFIX
	ACCESSOR="`vault read sys/auth -format=json|jq -r '.data."'$POLICYISSUER'/".accessor'`"
	sed -e "s,<issuer>,$ISSUER," -e "s/<${TEMPLATEPOLICY}>/$ACCESSOR/" -e "s/@<domain>/$policydomain/" $LIBEXEC/${TEMPLATEPOLICY}compatpolicy.template >>policies/${POLICY}.hcl.new
    done
done

POLICIES="$POLICIES $COMPATPOLICIES"

# global policies
for POLICY in tokencreate; do
    cat $LIBEXEC/${POLICY}policy.template >policies/${POLICY}.hcl.new
done
POLICIES="$POLICIES tokencreate"

for POLICY in $DELETEDPOLICIES; do
    rm -f policies/${POLICY}.hcl*
    vault policy delete ${POLICY}
done

for POLICY in $POLICIES; do
    if [ ! -f policies/${POLICY}.hcl ] || \
            ! cmp -s policies/${POLICY}.hcl.new policies/${POLICY}.hcl; then
        if [ -f policies/${POLICY}.hcl ]; then
            mv policies/${POLICY}.hcl policies/${POLICY}.hcl.old
        fi
        mv policies/${POLICY}.hcl.new policies/${POLICY}.hcl
	chmod a-w policies/${POLICY}.hcl
	vault policy write ${POLICY} policies/${POLICY}.hcl
    else
        rm -f policies/${POLICY}.hcl.new
    fi
done

echo "Completed vault configuration at `date`"
