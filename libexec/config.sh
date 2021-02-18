#!/bin/bash

usage()
{
    echo 'Usage: config.sh -nowait [all|module_to_force ...]'
    echo 'Policies are always regenerated from template and reloaded.'
    echo 'By default, reconfigure only modules not yet configured.'
    echo 'To force reconfiguring all modules, use "all".'
    echo 'To force reconfiguring specific modules, pass them as parameters.'
    echo 'May also force a type or issuer (before or after hyphen) instead of a module.'
    echo 'The enabled modules are:'
    echo "$ENABLEDMODS"
    echo "The -nowait option skips waiting for peers in multi-server config"
    exit 1
} >&2

echo
echo "Starting vault configuration at `date`"

PARAMS=/etc/htvault-config/config.d/parameters.sh
if [ ! -f $PARAMS ]; then
    echo "$PARAMS missing" >&2
    exit 1
fi
. $PARAMS

ISMASTER=true
if [ -n "$CLUSTERFQDN" ] && [ "$CLUSTERMASTER" != "$MYFQDN" ]; then
    ISMASTER=false
fi
SERVICENAME="${CLUSTERFQDN:-$MYFQDN}"
export VAULT_ADDR=http://127.0.0.1:8200
LIBEXEC=/usr/libexec/htvault-config
VARLIB=/var/lib/htvault-config
cd $VARLIB

if [ -n "$CLUSTERFQDN" ]; then
    vault operator raft join -format=json $VAULT_ADDR | jq -r keys[0]
fi

if [ ! -f vaultseal.txt ] && $ISMASTER; then
    # create a new DB
    vault operator init -key-shares=1 -key-threshold=1 -format=json >keys.json
    jq -r ".unseal_keys_b64[0]" keys.json >vaultseal.txt
    jq -r ".root_token" keys.json >~/.vault-token
    chmod 600 vaultseal.txt ~/.vault-token
    rm -f keys.json
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
	vault operator unseal `cat vaultseal.txt`
	if vault status >/dev/null; then
	    break
	fi
	let TRY+=1
	echo "Unseal try $TRY failed"
	sleep 1
    done
    if [ "$TRY" -eq "$MAX" ]; then
	echo "Giving up"
	exit 1
    fi
fi

if [ "$1" = "-nowait" ]; then
    shift
elif [ "`vault status -format=json|jq -r .storage_type`" = "raft" ]; then
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

if ! $ISMASTER; then
    echo "Completed vault configuration at `date`"
    exit 0
fi

ENABLEDMODS="`
    (vault auth list -format=json|jq keys
     vault secrets list -format=json|jq keys)| \
      egrep "(kerberos|oidc|oauth)"| \
       sed 's/"//g;s-/,--;s-[^ /]*/--'`"

for ARG; do
    case "$ARG" in
	-*) usage;;
    esac
done

echo "Enabled modules:"
echo "$ENABLEDMODS"

# remove newlines
ENABLEDMODS="`echo $ENABLEDMODS`"

FORCEMODS="$@"

shouldconfig()
{
    typeset MOD="${1##*/}"  # this is the equivalent of `basename $1`
    case " $ENABLEDMODS " in
	*" $MOD "*)
	    : it is enabled, see if it is to be forced
	    if [ "$FORCEMODS" != all ]; then
		for FORCEMOD in $FORCEMODS; do
		    case " $MOD " in
			*" $FORCEMOD "* | *"-$FORCEMOD "* | *" $FORCEMOD-"*)
			    : force it
			    echo "Configuring $MOD"
			    return
			    ;;
		    esac
		done
		: not forced
		return 1
	    fi
	    ;;

	*)  : not enabled
	    ;;
    esac
    echo "Configuring $MOD"
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

if [ -n "$LDAPURL" ] && shouldconfig kerberos; then
    #run this to enable kerberos debugging (if kerberos plugin is installed)
    #loadplugin auth-kerberos auth/kerberos

    vault auth disable kerberos
    vault auth enable \
	-passthrough-request-headers=Authorization \
	-allowed-response-headers=www-authenticate kerberos
    base64 /etc/krb5.keytab >krb5.keytab.base64
    vault write auth/kerberos/config \
	keytab=@$VARLIB/krb5.keytab.base64 \
	service_account="host/$SERVICENAME"
    rm -f krb5.keytab.base64

    vault write auth/kerberos/config/ldap \
	url="$LDAPURL" \
	userdn="$LDAPDN" \
	userattr="$LDAPATTR" \
	token_policies="kerberospolicy,tokencreatepolicy"
fi
if [ -n "$KERB2NAME" ] && shouldconfig kerberos-$KERB2NAME; then
    vault auth disable kerberos-$KERB2NAME
    vault auth enable -path=kerberos-$KERB2NAME \
	-passthrough-request-headers=Authorization \
	-allowed-response-headers=www-authenticate kerberos
    base64 /etc/krb5-$KERB2NAME.keytab >krb5.keytab.base64
    vault write auth/kerberos-$KERB2NAME/config \
	keytab=@$VARLIB/krb5.keytab.base64 \
	service_account="host/$SERVICENAME"
    rm -f krb5.keytab.base64

    vault write auth/kerberos-$KERB2NAME/config/ldap \
	url="$LDAPURL2" \
	userdn="$LDAPDN2" \
	userattr="$LDAPATTR2" \
	token_policies="kerberos2policy,tokencreatepolicy"
fi


loadplugin secrets-oauthapp secret/oauthapp
loadplugin auth-jwt auth/oidc

for POLICY in oidc kerberos kerberos2; do
    rm -f ${POLICY}policy.hcl
    echo "/* Do not edit this file, generated from ${POLICY}policy.template */" >${POLICY}policy.hcl
done

for TYPEMOD in auth/oidc secrets/oauthapp; do
    TYPE=${TYPEMOD%%/*}
    MOD=${TYPEMOD##*/}
    case " $ENABLEDMODS " in
        *" $MOD "*)
            # this can happen during the first initialization
            vault $TYPE disable $MOD
            ;;
    esac
done

for ISSUER in $ISSUERS; do 
    VPATH=oidc-$ISSUER
    REDIRECT_URIS="https://$SERVICENAME:8200/v1/auth/$VPATH/oidc/callback"

    for VAR in OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_SERVER_URL OIDC_SCOPES OIDC_CALLBACKMODE OIDC_USERCLAIM OIDC_GROUPSCLAIM; do
        IVAR="${ISSUER}_$VAR"
        eval "$VAR=\"${!IVAR}\""
    done

    if shouldconfig $VPATH; then
	vault auth disable $VPATH
	vault auth enable -path=$VPATH oidc
	VPATH=auth/$VPATH
	vault write $VPATH/config \
	    oidc_client_id="$OIDC_CLIENT_ID" \
	    oidc_client_secret="$OIDC_CLIENT_SECRET" \
	    default_role="default" \
	    oidc_discovery_url="$OIDC_SERVER_URL" 

	echo -n '{"claim_mappings": {"'$OIDC_USERCLAIM'" : "credkey"}, "oauth2_metadata": ["refresh_token"]}'| \
	  vault write $VPATH/role/default - \
	    role_type="oidc" \
	    user_claim="$OIDC_USERCLAIM" \
	    groups_claim="$OIDC_GROUPSCLAIM" \
	    oidc_scopes="$OIDC_SCOPES" \
	    policies=default,oidcpolicy,tokencreatepolicy \
	    callback_mode=$OIDC_CALLBACKMODE \
	    poll_interval=3 \
	    allowed_redirect_uris="$REDIRECT_URIS" \
	    verbose_oidc_logging=true
    fi

    VPATH=secret/oauth-$ISSUER
    if shouldconfig $VPATH; then
	vault secrets disable $VPATH
	vault secrets enable -path=$VPATH oauthapp
	# echo -n '{"provider_options": {"auth_code_url": "'$OIDC_SERVER_URL/authorize'", "token_url": "'$OIDC_SERVER_URL/$TOKEN_ENDPOINT'"}}'| \

	#echo -n '{"provider_options": {"issuer_url": "'$OIDC_SERVER_URL'", "auth_style": "in_header"}}'| \

	vault write $VPATH/config \
	    provider="oidc" \
	    provider_options="issuer_url=$OIDC_SERVER_URL" \
	    client_id="$OIDC_CLIENT_ID" \
	    client_secret="$OIDC_CLIENT_SECRET"
    fi

    for POLICY in oidc kerberos kerberos2; do
	POLICYISSUER="$POLICY"
	DOMAIN=$KERBPOLICYDOMAIN
	TEMPLATEPOLICY=$POLICY
	if [ "$POLICY" = oidc ]; then
	    POLICYISSUER="$POLICY-$ISSUER"
	elif [ "$POLICY" = kerberos2 ]; then
	    if [ -z "$KERB2NAME" ]; then
		rm -f ${POLICY}policy.hcl
		continue
	    fi
	    DOMAIN=$KERBPOLICYDOMAIN2
	    TEMPLATEPOLICY=kerberos
	    POLICYISSUER=kerberos-$KERB2NAME
	fi
	ACCESSOR="`vault read sys/auth -format=json|jq -r '.data."'$POLICYISSUER'/".accessor'`"
	sed -e "s,<vpath>,$VPATH," -e "s/<${TEMPLATEPOLICY}>/$ACCESSOR/" -e "s/@<domain>/$DOMAIN/" $LIBEXEC/${TEMPLATEPOLICY}policy.template >>${POLICY}policy.hcl
    done
done

# global policies
for POLICY in tokencreate; do
    cat $LIBEXEC/${POLICY}policy.template >${POLICY}policy.hcl
    vault policy write ${POLICY}policy ${POLICY}policy.hcl
done

echo "Loading policies"
for POLICY in oidc kerberos kerberos2 tokencreate; do
    if [ -f ${POLICY}policy.hcl ]; then
	chmod a-w ${POLICY}policy.hcl
	vault policy write ${POLICY}policy ${POLICY}policy.hcl
    fi
done

echo "Completed vault configuration at `date`"
