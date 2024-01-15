#!/usr/bin/env bash

source "$(dirname "$0")/ft-util/ft_util_inc_var"
source "$(dirname "$0")/ft-util/ft_util_inc_func"

if [ "$(whoami)" != "root" ]; then
  $S_LOG -s crit -d $S_NAME "Please run as root! You are only \"$(whoami)\"."
  exit 2
fi

app_name="futur-tech-synology-autoblock"
src_dir="/usr/local/src/${app_name}"
bin_dir="/usr/local/bin/${app_name}"

$S_LOG -d $S_NAME "Start $S_NAME $*"

echo "
  INSTALL NEEDED PACKAGES & FILES
------------------------------------------"

mkdir_if_missing "${bin_dir}"

$S_DIR/ft-util/ft_util_file-deploy "$S_DIR/autoblocksynology.sh" "${bin_dir}/autoblocksynology.sh"
$S_DIR/ft-util/ft_util_file-deploy "$S_DIR/ft-util/ft_util_log" "${bin_dir}/ft_util_log"
$S_DIR/ft-util/ft_util_file-deploy "$S_DIR/ft-util/ft_util_inc_var" "${bin_dir}/ft_util_inc_var"

$S_DIR/ft-util/ft_util_conf-update -s "$S_DIR/autoblocksynology.conf" -d "/usr/local/etc/autoblocksynology.conf"

[ ! -e "/var/log/${app_name}.log" ] && touch /var/log/${app_name}.log

$S_LOG -d "$S_NAME" "End $S_NAME"
