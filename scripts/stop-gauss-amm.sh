#!/usr/bin/env bash
set -euo pipefail

install_dir=/home/sqlrush/gauss-amm-src/mppdb_temp_install
data_dir=/home/sqlrush/gauss-amm-data

export GAUSSHOME="$install_dir"
export PATH="$install_dir/bin:$PATH"
export LD_LIBRARY_PATH="$install_dir/lib:$install_dir/lib/postgresql:$install_dir/lib/krb5"

gs_ctl stop -D "$data_dir" -m fast
