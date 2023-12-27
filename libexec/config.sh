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
    if $ISMASTER; then
        echo "Continuing after HA setup at `date`"
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

VTOKEN="X-Vault-Token: $(<~/.vault-token)"
if [ "$_old_ratelimits" != "$_ratelimits" ]; then
    # The ratelimits list changed
    for RATELIMIT in $_old_ratelimits; do
        if ! [[ " $_ratelimits " == *" $RATELIMIT "* ]]; then
            echo "Deleting $RATELIMIT rate limit"
            curl -sS -H "$VTOKEN" -X DELETE $VAULT_ADDR/v1/sys/quotas/rate-limit/"$RATELIMIT"
        fi
    done
fi
for RATELIMIT in $_ratelimits; do
    CHANGED=false
    for VAR in path rate interval block_interval; do
        eval $VAR=\"\$_ratelimits_${RATELIMIT//-/_}_$VAR\"
        eval old_$VAR=\"\$_old_ratelimits_${RATELIMIT//-/_}_$VAR\"
        if eval [ \"\$$VAR\" != \"\$old_$VAR\" ]; then
            CHANGED=true
        fi
    done
    if ! $CHANGED; then
        continue
    fi
    echo "Setting $RATELIMIT rate limit"
    curl -sS -H "$VTOKEN" -X POST -d @- $VAULT_ADDR/v1/sys/quotas/rate-limit/"$RATELIMIT" <<EOF
    {
        "path" : "$path",
        "rate" : "$rate",
        "interval" : "$interval",
        "block_interval" : "$block_interval"
    }
EOF
done

ENBLEDMODS=""
updateenabledmods()
{
    ENABLEDMODS="`
        (vault auth list -format=json|jq keys
         vault secrets list -format=json|jq keys)| \
          grep /|sed 's/"//g;s-/,--;s-[^ /]*/--'`"
    # remove newlines and extra spaces
    ENABLEDMODS="`echo $ENABLEDMODS`"
}
updateenabledmods

modenabled()
{
    case " $ENABLEDMODS " in
	*" $1 "*)
            return 0
            ;;
    esac
    return 1
}

loadplugin()
{
    typeset PLUGIN="vault-plugin-$1.sh"
    typeset SHA="`sha256sum $LIBEXEC/plugins/$PLUGIN|awk '{print $1}'`"
    typeset CATPATH="sys/plugins/catalog/$2"
    if [ "`vault read -field=sha256 $CATPATH 2>/dev/null`" != "$SHA" ]; then
	echo "Defining plugin $1"
	vault write $CATPATH sha256=$SHA command=$PLUGIN
    fi
}

AUDITLOG="${_cluster_auditlog:-/var/log/htvault-config/auditlog}"
AUDITFILEPATH="$(vault audit list -format=json|jq -r .\"file/\".options.file_path)"
if [ "$AUDITFILEPATH" != "$AUDITLOG" ]; then
    if [ "$AUDITFILEPATH" != "null" ]; then
        vault audit disable file
    fi
    if [ "$AUDITLOG" != "none" ]; then
        echo "Enabling audit log at $AUDITLOG"
        vault audit enable file file_path=$AUDITLOG log_raw=true
    fi
fi

process_policy()
{
    POLICY=$1
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
}

mkdir -p policies
rm -f policies/*.new # may be left over from previous aborted run
POLICIES=""
DELETEDPOLICIES=""
ISFIRST=true
POLICYTYPES="oidc"
USESSH=false
if [ "$_ssh_self_registration" != "" ]; then
    USESSH=true
    POLICYTYPES="$POLICYTYPES ssh"
    if [ "$_ssh_self_registration" == "allowed" ]; then
        POLICYTYPES="$POLICYTYPES sshregister"
    fi
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
    
    if modenabled kerberos$KERBSUFFIX; then
        # clean out old-style of kerberos
        echo "Disabling kerberos$KERBSUFFIX"
        vault auth disable kerberos$KERBSUFFIX
        POLICYNAME="kerberos${KERBNAME}"
        DELETEDPOLICIES="$DELETEDPOLICIES $POLICYNAME"
    fi

    # construct list of kerberos services
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
done

loadplugin secrets-oauthapp secret/oauth
loadplugin auth-jwt auth/oidc
loadplugin auth-ssh auth/ssh
updateenabledmods
if ! modenabled oauth; then
    OAUTHENABLED=false
    vault secrets enable -path=secret/oauth oauth
else
    OAUTHENABLED=true
fi
if $USESSH; then
    if ! modenabled ssh; then
        vault auth enable ssh
        vault write auth/ssh/config ssh_ca_public_keys=
    fi
    if [ "$(vault read -field=token_policies auth/ssh/config 2>/dev/null)" != "[ssh tokenops]" ]; then
        vault write auth/ssh/config token_policies=ssh,tokenops
    fi
else
    if modenabled ssh; then
        vault auth disable ssh
    fi
fi

# disable modules that can be enabled during the first initialization
if modenabled oauthapp; then
    vault secrets disable oauthapp
fi
if modenabled oidc; then
    vault auth disable oidc
fi

# disable old-style per-issuer secret plugins
vault secrets list|grep secret/oauth-|awk '{print $1}'|while read MOD; do
    vault secrets disable $MOD
done

updateenabledmods

check_secrets_config()
{
    # Although slower than just always writing it out, this avoids excess
    #   messages if nothing is changing
    CONFIGJSON="`vault read $1/config -format=json 2>/dev/null`"
    DOCONFIG=false
    if [ "`echo "$CONFIGJSON"|jq -r .data.tune_refresh_check_interval_seconds`" != 0 ]; then
        echo "Disabling refresh checks on $1"
        DOCONFIG=true
    fi
    if [ "`echo "$CONFIGJSON"|jq -r .data.default_server`" != "legacy" ]; then
        echo "Setting default server on $1"
        DOCONFIG=true
    fi
    if $DOCONFIG; then
        vault write $1/config tune_refresh_check_interval_seconds=0 default_server=legacy
    fi
}
check_secrets_config secret/oauth

disable_role()
{
    # assumes $ISSUER and $ROLE are set
    if [ -n "$_old_kerberos" ]; then
        KERBSERVICE=kerberos-${ISSUER}_${ROLE}
        POLICYNAME="$KERBSERVICE"
        DELETEDPOLICIES="$DELETEDPOLICIES $POLICYNAME"
        if modenabled $KERBSERVICE; then
            echo "Disabling $KERBSERVICE"
            vault auth disable $KERBSERVICE
            updateenabledmods
        fi
    fi
    POLICYNAME=oidc-${ISSUER}_${ROLE}
    DELETEDPOLICIES="$DELETEDPOLICIES $POLICYNAME"
}

# global policies
GLOBALPOLICIES="tokenops"
for POLICY in $GLOBALPOLICIES; do
    cat $LIBEXEC/${POLICY}policy.template >policies/${POLICY}.hcl.new
    process_policy $POLICY
done

if [ "$_old_issuers" != "$_issuers" ]; then
    # The issuers list changed
    for ISSUER in $_old_issuers; do
        if ! [[ " $_issuers " == *" $ISSUER "* ]]; then
            echo "Disabling oidc-$ISSUER and secret/oauth/servers/$ISSUER"
            vault auth disable oidc-$ISSUER
            vault delete secret/oauth/servers/$ISSUER

            for VAR in roles; do
                eval old_$VAR=\"\$_old_issuers_${ISSUER//-/_}_$VAR\"
            done

            for ROLE in $old_roles; do
                disable_role
            done
        fi
    done
    updateenabledmods
fi
CURRENTKERBNAME=""
KERBCONFIGCHANGED=false
for ISSUER in $_issuers; do 
    echo "Checking issuer $ISSUER"
    VPATH=oidc-$ISSUER
    REDIRECT_URIS="https://$SERVICENAME:8200/v1/auth/$VPATH/oidc/callback"

    for VAR in clientid secret url roles callbackmode credclaim kerbservice; do
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

                    disable_role
                fi
            done
        fi
        for VAR in credclaim callbackmode SERVICENAME; do
            if eval [ \"\$$VAR\" != \"\$old_$VAR\" ]; then
                CHANGED=true
                break
            fi
        done
        if [ ! -f policies/tokenops.hcl ]; then
            CHANGED=true
        fi
        if [ "$_ssh_self_registration" != "$_old_ssh_self_registration" ]; then
            if [ "$_ssh_self_registration" = "allowed" ]; then
                CHANGED=true
            elif [ "$_old_ssh_self_registration" = "allowed" ]; then
                CHANGED=true
                DELETEDPOLICIES="$DELETEDPOLICIES sshregister-${ISSUER}"
            fi
        fi
    fi

    KEYTAB=""
    if [ -n "$FIRSTKERBNAME$OTHERKERBNAMES" ]; then
        if [ "$kerbservice" != "" ]; then
            KERBNAME="$kerbservice"
        elif [[ " $OTHERKERBNAMES " == *" $ISSUER "* ]]; then
            KERBNAME="$ISSUER"
        else
            KERBNAME="$FIRSTKERBNAME"
        fi
        KEYTAB=/etc/krb5-$KERBNAME.keytab
        if [ "$KERBNAME" = "$FIRSTKERBNAME" ] && [ ! -f $KEYTAB ]; then
            KEYTAB=/etc/krb5.keytab
        fi
        if [ ! -f "$KEYTAB" ]; then
            echo "$KEYTAB not found, skipping $kerbservice kerberos for $ISSUER issuer"
            KEYTAB=""
        fi

        if [ -n "$KEYTAB" ] && [ "$KERBNAME" != "$CURRENTKERBNAME" ]; then
            CURRENTKERBNAME="$KERBNAME"
            KERBCONFIGCHANGED=false
            if [ ! -f config.json.old ] || [ $KEYTAB -nt config.json.old ]; then
                echo "$KEYTAB changed since last configuration"
                KERBCONFIGCHANGED=true
            elif [ "$SERVICENAME" != "$old_SERVICENAME" ]; then
                KERBCONFIGCHANGED=true
            fi
            for VAR in ldapattr ldapdn ldapurl policydomain; do
                eval $VAR=\"\$_kerberos_${KERBNAME//-/_}_$VAR\"
                eval old_$VAR=\"\$_old_kerberos_${KERBNAME//-/_}_$VAR\"
                if eval [ \"\$$VAR\" != \"\$old_$VAR\" ]; then
                    KERBCONFIGCHANGED=true
                fi
            done
        fi
        if [ ! -f policies/tokenops.hcl ]; then
            KERBCONFIGCHANGED=true
        fi
    fi

    for ROLE in $roles; do
        # Do kerberos before policies so all the kerberos accessors are
        #  available.  Issuer accessors are already created above.

        if [ -n "$KEYTAB" ]; then
            KERBCHANGED=$KERBCONFIGCHANGED
            if [ "$kerbservice" != "$old_kerbservice" ]; then
                KERBCHANGED=true
            fi
            KERBSERVICE=kerberos-${ISSUER}_${ROLE}
            if ! modenabled $KERBSERVICE; then
                KERBCHANGED=true
                echo "Enabling $KERBERVICE"
                vault auth enable -path=$KERBSERVICE \
                    -passthrough-request-headers=Authorization \
                    -allowed-response-headers=www-authenticate kerberos
            fi

            POLICYNAME=$KERBSERVICE
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
                    token_policies="$POLICYNAME,tokenops"
            fi
        fi

        for POLICYTYPE in $POLICYTYPES; do
            ACCESSORTYPE=$POLICYTYPE
            if [ "$POLICYTYPE" = kerberos ]; then
                POLICYISSUER="${POLICYTYPE}-${ISSUER}_${ROLE}"
                POLICYNAME="$POLICYISSUER"
            elif [ "$POLICYTYPE" = ssh ]; then
                POLICYISSUER="${POLICYTYPE}"
                POLICYNAME="$POLICYISSUER"
            elif [ "$POLICYTYPE" = sshregister ]; then
                ACCESSORTYPE=oidc
                POLICYISSUER="${ACCESSORTYPE}-${ISSUER}"
                POLICYNAME="${POLICYTYPE}-${ISSUER}"
            elif [ "$POLICYTYPE" = oidc ]; then
                POLICYISSUER="${POLICYTYPE}-${ISSUER}"
                POLICYNAME="${POLICYISSUER}_${ROLE}"
            else
                echo "Unrecognized policy type $POLICYTYPE"
                continue
            fi
            if [[ " $POLICIES " == *" $POLICYNAME "* ]]; then
                # already done
                continue
            fi
            OLDPOLICYNAME="${POLICYTYPE}${ISSUER}_${ROLE}"
            if vault policy read $OLDPOLICYNAME >/dev/null 2>&1; then
                # only happens once after an upgrade
                DELETEDPOLICIES="$DELETEDPOLICIES $OLDPOLICYNAME"
            fi
            ACCESSOR="`vault read sys/auth -format=json|jq -r '.data."'$POLICYISSUER'/".accessor'`"
            sed -e "s,<issuer>,$ISSUER," -e "s/<${ACCESSORTYPE}>/$ACCESSOR/g" -e "s/@<domain>/$policydomain/" -e "s/<role>/$ROLE/" $LIBEXEC/${POLICYTYPE}policy.template >>policies/${POLICYNAME}.hcl.new
            POLICIES="$POLICIES $POLICYNAME"
            process_policy $POLICYNAME
        done

        eval scopes=\"\$_issuers_${ISSUER//-/_}_roles_${ROLE//-/_}_scopes\"
        eval old_scopes=\"\$_old_issuers_${ISSUER//-/_}_roles_${ROLE//-/_}_scopes\"
        POLICYNAME=oidc-${ISSUER}_${ROLE}
        SSHPOLICY=""
        if [ "$_ssh_self_registration" == "allowed" ]; then
            SSHPOLICY=",sshregister-${ISSUER}"
        fi
        if ! $ENABLED || $CHANGED || [ "$scopes" != "$old_scopes" ] || [ ! -f policies/${POLICYNAME}.hcl ]; then
            # use some json input in order to have nested parameters
            echo "Configuring $VPATH role $ROLE with scopes $scopes"
            vault write $VPATH/role/$ROLE - \
                role_type="oidc" \
                user_claim="$credclaim" \
                groups_claim="" \
                oidc_scopes="$scopes" \
                token_no_default_policy=true \
                policies=${POLICYNAME}${SSHPOLICY},tokenops \
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

    done

    CHANGED=false
    if $ENABLED; then
        for VAR in url clientid; do
            if eval [ \"\$$VAR\" != \"\$old_$VAR\" ]; then
                CHANGED=true
                # server or clientid changed, disable the server to
                #  clear out all old secrets
                echo "Disabling secret/oauth/servers/$ISSUER"
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

    if ! $ENABLED || ! $OAUTHENABLED || $CHANGED; then
        SPATH=secret/oauth/servers/$ISSUER
        echo "Configuring $SPATH"
        vault write $SPATH - \
            provider="oidc" \
            provider_options="issuer_url=$url" \
            <<EOF
            {
                "client_id": "$clientid",
                "client_secret": "$secret"
            }
EOF
    fi
done

if [ -f policies/tokencreate.hcl ]; then
    DELETEDPOLICIES="$DELETEDPOLICIES tokencreate"
fi

for POLICY in $DELETEDPOLICIES; do
    rm -f policies/${POLICY}.hcl*
    vault policy delete ${POLICY}
done

echo "Completed vault configuration at `date`"
