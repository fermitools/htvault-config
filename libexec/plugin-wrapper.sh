#!/bin/bash
export VAULT_LOG_LEVEL=debug
exec `dirname $0`/`basename $0 .sh` "$@"
