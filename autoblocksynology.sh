#!/bin/sh

###############################################################################
# Script from the tutorial on nas-forum.com by Superthx
###############################################################################
# This script accepts one parameter:  "reset"
# If it is present, the script starts by deleting the IPs not permanently blocked

export LOG_FILE="/var/log/futur-tech-synology-autoblock.log"
source /usr/local/etc/autoblocksynology.conf
source /usr/local/bin/futur-tech-synology-autoblock/ft_util_inc_var

if [ "$(whoami)" != "root" ] ; then $S_LOG -s crit -d $S_NAME "Please run as root! You are only \"$(whoami)\"." ; exit 2 ; fi

version="v0.0.3"
db="/etc/synoautoblock.db"
temp_file="/tmp/futur-tech-synology-autoblock.tmp"

# This function deletes all IP addresses from the AutoBlockIP table in the database
# that are marked for denial (DENY = 1) but are not permanently blocked (ExpireTime > 0).
ResetBlockedIPs(){
    sqlite3 $db "DELETE FROM AutoBlockIP WHERE DENY = 1 AND ExpireTime > 0;"
}

# This function sets up the blocking period by calculating the time to stop blocking
# based on the current time, frequency of update (Update_Freq), plus a margin. It updates the 'Var' table in the database
# with the calculated stop time.
BlockingPeriodSetup(){
    start=$(date +%s)
    block_off=$((start + Update_Freq * 3 * 3600 + 600)) # * 3 is in case the list failed to download, there are 2 more try before being automatically expired. "+600" is to add an extra 10min margin.

    # Dropping the 'Var' table if it exists and creating it again
    sqlite3 $db "
        DROP TABLE IF EXISTS Var;
        CREATE TABLE Var (name TEXT PRIMARY KEY, value TEXT);"

    # Inserting 'stop' value into 'Var' table
    sqlite3 $db "INSERT INTO Var VALUES ('stop', $block_off)"
}

# This function fetches IP addresses from a given URL, filters out comments,
# and logs the number of IPs loaded or any failure in loading.
FetchIPsFromURL(){
    local url=$1
    local fetched_ips

    # Fetch IPs and filter out comments
    fetched_ips=$(wget -qO- "$url" | grep -v "^#")

    # Check if IPs are fetched successfully
    if [ -n "$fetched_ips" ]; then
        all_fetched_ips+=$'\n'"$fetched_ips"
        $S_LOG -s debug -d $S_NAME "Loaded $(echo "$fetched_ips" | wc -l) IPs from the URL $url"
    else
        $S_LOG -s err -d $S_NAME "Failed to load IPs from the URL $url"
    fi
}


# This function fetches IP addresses from specified URLs (List_Urls) and the personal filter file.
# It processes each URL, downloads the list of IPs, and merges them into a temporary file.
FetchIPs(){
    local all_fetched_ips=$(cat /usr/local/etc/autoblocksynology-extra-ip.txt) # personal filter file

    for url in $List_Urls; do
        host=$(echo $url | sed -n "s/^https\?:\/\/\([^/]\+\).*$/\1/p")
        case $host in
            lists.blocklist.de)
                for chx in $BlocklistDE_choice; do
                    FetchIPsFromURL "$url$chx.txt"
                done
                ;;

            raw.githubusercontent.com|blocklist.greensnow.co|cinsarmy.com)
                FetchIPsFromURL "$url"
                ;;

            *)
                $S_LOG -s err -d $S_NAME "Processing for $url is not implemented"
                ;;
        esac
    done

    # Remove duplicates and store the result
    echo "$all_fetched_ips" | grep -v "^#" | sort -u -f -o $temp_file

    ## debug
    # head -n 2000 "$temp_file" > "${temp_file}_tmp" && mv "${temp_file}_tmp" "$temp_file"

    $S_LOG -d $S_NAME "Total loaded IPs: $(wc -l "$temp_file")"

}

# This function updates the known IP addresses in the database. It imports the IPs from the temporary file
# into a temporary table in the database, sets their expiration time, and updates the AutoBlockIP table
# with these new values. Finally, it cleans up the temporary table.
UpdateKnownIPs(){

    # Dropping and creating the 'Var' table
    sqlite3 $db "
        DROP TABLE IF EXISTS Var;
        CREATE TABLE Var (name TEXT PRIMARY KEY, value TEXT);"

    # Inserting the 'stop' value into the 'Var' table
    sqlite3 $db "INSERT INTO Var VALUES ('stop', $block_off)"

    # Processing the temporary file and updating the database
    sqlite3 $db "
        DROP TABLE IF EXISTS Tmp;
        CREATE TABLE Tmp (IP VARCHAR(50) PRIMARY KEY);"

    # Importing the CSV data into the Tmp table
    sqlite3 $db <<EOF
.mode csv
.import ${temp_file} Tmp
EOF

    sqlite3 $db "
        ALTER TABLE Tmp ADD COLUMN ExpireTime DATE;
        ALTER TABLE Tmp ADD COLUMN Old BOOLEAN;
        UPDATE Tmp SET ExpireTime = (SELECT value FROM Var WHERE name = 'stop');
        UPDATE Tmp SET Old = (SELECT 1 FROM AutoBlockIP WHERE Tmp.IP = AutoBlockIP.IP);
        UPDATE AutoBlockIP SET ExpireTime = (SELECT ExpireTime FROM Tmp WHERE AutoBlockIP.IP = Tmp.IP AND Tmp.Old = 1) WHERE EXISTS (SELECT ExpireTime FROM Tmp WHERE AutoBlockIP.IP = Tmp.IP AND Tmp.Old = 1);
        DELETE FROM Tmp WHERE Old = 1;
        DROP TABLE Var;"

    rm $temp_file # Cleans up the temporary file
}

# A utility function that converts a hexadecimal number (passed as a parameter) into its decimal equivalent.
HexToDec(){
if [ "$1" != "" ]; then
    printf "%d" "$(( 0x$1 ))"
fi
}

# This function standardizes the format of IP addresses. It converts IPv4 addresses to a standard format
# and handles IPv6 addresses, ensuring they are in the correct format for processing and storage.
StandardizeIPFormat(){
    local ip_addr="$1"
    local ipstd=''

    if [[ -z "$ip_addr" ]]; then
        return
    fi

    if [[ $ip_addr =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        ipstd=$(printf "0000:0000:0000:0000:0000:FFFF:%02X%02X:%02X%02X" ${ip_addr//./' '})
    elif [[ $ip_addr =~ : ]]; then
        local ip6=${ip_addr//::/"$(echo ":::::::::" | sed "s/${ip_addr//[^:]/}/:0/g")"}
        ip6=${ip6//:/ }
        ipstd=$(printf "%04X:%04X:%04X:%04X:%04X:%04X:%04X:%04X" $(HexToDec ${ip6}))
    else
        $S_LOG -s warn -d $S_NAME "IP not processed (incorrect IP format): $ip_addr"
        return
    fi

    if [[ -n "$ipstd" ]]; then 
        formatted_ips+="${ip_addr},${start},${block_off},${ipstd}"$'\n'
        # echo $ip_addr
    fi
}

# This function is specific for NAS systems. It inserts the new IP addresses into the AutoBlockIP table.
InsertNewIPsNAS(){
    # Inserting data into the AutoBlockIP table from the 'Tmp' table
    sqlite3 $db "INSERT INTO AutoBlockIP SELECT IP, RecordTime, ExpireTime, 1, IPStd, NULL, NULL FROM Tmp WHERE IPStd IS NOT NULL;"

    # Dropping the 'Tmp' table
    sqlite3 $db "DROP TABLE Tmp;"
}

# Similar to InsertNewIPsNAS, this function inserts new IP addresses into the AutoBlockIP table.
InsertNewIPsRouter(){
    # Inserting data into the AutoBlockIP table from the 'Tmp' table
    sqlite3 $db "INSERT INTO AutoBlockIP SELECT IP, RecordTime, ExpireTime, 1, IPStd FROM Tmp WHERE IPStd IS NOT NULL;"

    # Dropping the 'Tmp' table
    sqlite3 $db "DROP TABLE Tmp;"
}

# This function orchestrates the process of inserting new IPs. It standardizes the format of each new IP
# and then decides whether to call InsertNewIPsNAS or InsertNewIPsRouter based on the shell type.
InsertNewIPs(){
    newip="$(sqlite3 $db "SELECT IP FROM Tmp WHERE IP <>''")"
    
    if [ -z "$newip" ]; then
        $S_LOG -d $S_NAME "No new IPs to process"
    else
        $S_LOG -d $S_NAME "Processing $(echo "$newip" | wc -l) new IPs"

        formatted_ips=""  # Global variable to store formatted IPs
        for ip in $newip; do StandardizeIPFormat "$ip" ; done
        echo "$formatted_ips" | head -n -1 > $temp_file

        if [ -f $temp_file ]; then
            # Dropping the 'Tmp' table if it exists and creating it again
            sqlite3 $db "
                DROP TABLE IF EXISTS Tmp;
                CREATE TABLE Tmp (IP VARCHAR(50) PRIMARY KEY, RecordTime DATE, ExpireTime DATE, IPStd VARCHAR(50));
                "

            # Importing data from the temporary file into the 'Tmp' table
            sqlite3 $db <<EOF
.mode csv
.import ${temp_file} Tmp
EOF

            if [[ $TypeShell == "bash" ]];then
                InsertNewIPsNAS
            elif [[ $TypeShell == "sh" ]];then
                InsertNewIPsRouter
            fi    
            rm $temp_file # Cleans up the temporary file
        fi
    fi

}

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
    if [[ "$1" == "reset" ]]; then
        ResetBlockedIPs
        $S_LOG -d $S_NAME "The blocking of IPs not blocked permanently has been removed."
    else
        $S_LOG -s crit -d $S_NAME "Incorrect parameter $1! Only allowed parameter: 'reset'"
        $S_LOG -s crit -d $S_NAME "Exiting script"
        exit 1
    fi
fi

BlockingPeriodSetup 
FetchIPs
UpdateKnownIPs
InsertNewIPs 
$S_LOG -d $S_NAME "Script finished"
exit 0
