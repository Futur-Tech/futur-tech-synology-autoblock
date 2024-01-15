#!/bin/sh

###############################################################################
# Script from the tutorial on nas-forum.com by Superthx
###############################################################################
# This script accepts one parameter:  "raz"
# If it is present, the script starts by deleting the IPs not permanently blocked

export LOG_FILE="/var/log/futur-tech-synology-autoblock.log"
source /usr/local/etc/autoblocksynology.conf
source /usr/local/bin/futur-tech-synology-autoblock/ft_util_inc_var

if [ "$(whoami)" != "root" ] ; then $S_LOG -s crit -d $S_NAME "Please run as root! You are only \"$(whoami)\"." ; exit 2 ; fi

version="v0.0.3"
db="/etc/synoautoblock.db"
temp_dir="/tmp/autoblock_synology"
temp_file1="${temp_dir}/fichiertemp1"
temp_file2="${temp_dir}/fichiertemp2"
marge=60

ResetBlockedIPs(){
sqlite3 $db <<EOL
delete from AutoBlockIP where DENY = 1 and ExpireTime > 0;
EOL
}

InitialTests(){
$S_LOG -d $S_NAME "Starting the script `basename $0` $version"
if [ -f  "/bin/bash" ]; then
    TypeShell="bash"
elif [ -f  "/bin/sh" ]; then    
    TypeShell="sh"
else
    $S_LOG -s crit -d $S_NAME "Exiting script"
    exit 1
fi
if [[ $# -gt 0 ]]; then
    if [[ "$1" == "raz" ]]; then
        ResetBlockedIPs
        $S_LOG -d $S_NAME "Le blocage des IP non bloquées définitivement a été supprimé"
    else
        $S_LOG -s crit -d $S_NAME "Parametre $1 incorrect! Seul parametre autorisé: 'raz'"
        $S_LOG -s crit -d $S_NAME "Exiting script"
        exit 1
    fi
fi
if [ ! -d  "/tmp" ]; then  # failsafe
    $S_LOG -s crit -d $S_NAME "The tmp folder does not exist. Exiting script for safety."
elif [ ! -d  $temp_dir ]; then
    mkdir $temp_dir
    chmod 755 $temp_dir
fi
}

BlockingPeriodSetup(){
start=`date +%s`
block_off=$((start+Freq*2*3600+$marge))
sqlite3 $db <<EOL
drop table if exists Var;
create table Var (name text primary key, value text);
EOL
`sqlite3 $db "insert into Var values ('stop', $block_off)"`
}

FetchIPs(){
if [ -f  $Personal_Filter ];then
    cat "$Personal_Filter" > $temp_file1
else
    touch $temp_file1
    touch $Personal_Filter
fi
for url in $List_Urls; do
    host=`echo $url | sed -n "s/^https\?:\/\/\([^/]\+\).*$/\1/p"`
    case $host in
        lists.blocklist.de)
            nb=0
            for chx in $BlocklistDE_choice; do
                wget -q "$url$chx.txt" -O $temp_file2
                nb2=$(wc -l $temp_file2 | cut -d' ' -f1)
                if [[ $nb2 -gt 0 ]];then
                        sort -ufo $temp_file1 $temp_file2 $temp_file1
                    nb=$(($nb+$nb2))
                else
                    $S_LOG -s err -d $S_NAME "Failed to load IPs from the site $host$BlocklistDE_choice.txt"
                fi
            done
            ;;
        
        raw.githubusercontent.com|blocklist.greensnow.co|cinsarmy.com)
            wget -q "$url" -O $temp_file2
            nb=$(wc -l $temp_file2 | cut -d' ' -f1)
            if [[ $nb -gt 0 ]];then
                sort -ufo $temp_file1 $temp_file2 $temp_file1
             else
                $S_LOG -s err -d $S_NAME "Failed to load IPs from the site $host"
            fi
            ;;

        *)
            $S_LOG -s err -d $S_NAME "Processing for $url is not implemented"
            nb=0
            ;;
    esac
done
rm $temp_file2
nb_ligne=$(wc -l  $temp_file1 | cut -d' ' -f1)
}

UpdateKnownIPs(){
sqlite3 $db <<EOL
drop table if exists Var;
create table Var (name text primary key, value text);
EOL
`sqlite3 $db "insert into Var values ('stop', $block_off)"
`sqlite3 $db <<EOL
drop table if exists Tmp;
create table Tmp (IP varchar(50) primary key);
.mode csv
.import ${temp_file1} Tmp
alter table Tmp add column ExpireTime date;
alter table Tmp add column Old boolean;
update Tmp set ExpireTime = (select value from Var where name = 'stop');
update Tmp set Old = (
select 1 from AutoBlockIP where Tmp.IP = AutoBlockIP.IP);
update AutoBlockIP set ExpireTime=(
select ExpireTime from Tmp where AutoBlockIP.IP = Tmp.IP and Tmp.Old = 1) 
where exists (
select ExpireTime from Tmp where AutoBlockIP.IP = Tmp.IP and Tmp.Old = 1);
delete from Tmp where Old = 1;
drop table Var;
EOL
rm $temp_file1
}

HexToDec(){
if [ "$1" != "" ];then
    printf "%d" "$(( 0x$1 ))"
fi
}

StandardizeIPFormat(){
ipstd=''
if [[ $ip != '' ]]; then
    if expr "$ip" : '[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' > \
        /dev/null; then
        ipstd=$(printf "0000:0000:0000:0000:0000:FFFF:%02X%02X:%02X%02X" \
            ${ip//./' '})
    elif [[ $ip != "${1#*:[0-9a-fA-F]}" ]]; then
        ip6=$ip
        echo $ip6 | grep -qs "^:" && $ip6="0${ip6}"
        if echo $ip6 | grep -qs "::"; then
            separator=$(echo $ip6 | sed 's/[^:]//g')
            missing=$(echo ":::::::::" | sed "s/$separator//")
            replacement=$(echo $missing | sed 's/:/:0/g')
            ip6=$(echo $ip6 | sed "s/::/$replacement/")
        fi
        blocks=$(echo $ip6 | grep -o "[0-9a-f]\+")
        set $blocks
        ipstd=$(printf "%04X:%04X:%04X:%04X:%04X:%04X:%04X:%04X" \
            $(HexToDec $1) $(HexToDec $2) $(HexToDec $3) $(HexToDec $4) \
            $(HexToDec $5) $(HexToDec $6) $(HexToDec $7) $(HexToDec $8))
    else
        $S_LOG -s warn -d $S_NAME -d "${relay_name}" "IP not processed (incorrect IP format): $ip"
    fi
    if [[ $ipstd != '' ]]; then 
        printf '%s,%s,%s,%s\n' "$ip" "$start" "$block_off" "$ipstd" >> $temp_file1
    fi
fi
}

import_nouvelles_ip(){
sqlite3 $db <<EOL
drop table Tmp;
create table Tmp (IP varchar(50) primary key, RecordTime date, 
ExpireTime date, IPStd varchar(50));
.mode csv
.import ${temp_file1} Tmp
EOL
}

InsertNewIPsNAS(){
sqlite3 $db <<EOL
insert into AutoBlockIP 
select IP, RecordTime, ExpireTime, 1, IPStd, NULL, NULL 
from Tmp where IPStd is not NULL;
drop table Tmp;
EOL
}

InsertNewIPsRouter(){
sqlite3 $db <<EOL
insert into AutoBlockIP 
select IP, RecordTime, ExpireTime, 1, IPStd 
from Tmp where IPStd is not NULL;
drop table Tmp;
EOL
}

InsertNewIPs(){
newip=`sqlite3 $db "select IP from Tmp where IP <>''"`
for ip in $newip; do
   StandardizeIPFormat
done
if [ -f  $temp_file1 ]; then
    import_nouvelles_ip
    if [[ $TypeShell == "bash" ]];then
        InsertNewIPsNAS
    elif [[ $TypeShell == "sh" ]];then
        InsertNewIPsRouter
    fi    
    rm $temp_file1
fi
}

cd `dirname $0`
InitialTests $1
BlockingPeriodSetup 
FetchIPs
UpdateKnownIPs
InsertNewIPs 
$S_LOG -d $S_NAME "Script finished"
exit 0
