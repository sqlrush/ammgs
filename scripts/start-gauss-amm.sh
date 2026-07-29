#!/usr/bin/env bash
set -euo pipefail

install_dir=/home/sqlrush/gauss-amm-src/mppdb_temp_install
data_dir=/home/sqlrush/gauss-amm-data
server_log=/home/sqlrush/gauss-amm-server.log
config_sql=/mnt/mac/Users/sqlrush/memtest/vm/configure-gauss-amm.sql

export GAUSSHOME="$install_dir"
export GAUSSLOG=/home/sqlrush/gauss-amm-log
export PATH="$install_dir/bin:$PATH"
export LD_LIBRARY_PATH="$install_dir/lib:$install_dir/lib/postgresql:$install_dir/lib/krb5"

mkdir -p "$GAUSSLOG"

gs_ctl start -D "$data_dir" -Z single_node -l "$server_log" -o \
  "-p 15432 -c listen_addresses=127.0.0.1"

gsql -X -v ON_ERROR_STOP=1 -p 15432 -d postgres -f "$config_sql"
