#!/bin/bash -e

# 脚本可使用在Syno-7.2，其他版本未测试
# 泛域名如*.a.com填写a.com即可
cert_domain="ai0128.com"
# ftp/nfs等定期上传更新证书的目录
cert_source_path="/volume1/homes/certd/_ai0128_com"
# 最好要指定默认证书文件名称，这样就能并行使用多个脚本
cert_id_default=""
# 默认保存cert_id的文件名
cert_id_default_file="./cert_id_default"

log_path="$cert_source_path/renewal.log"

echo "[$(date +"%Y-%m-%d %H:%M:%S")]Syno_cert_renewal_base_local_dir start:" >> $log_path

[[ $EUID == 0 ]] || {
    echo >&2 "This script must be run as root!" >> $log_path
	echo "[$(date +"%Y-%m-%d %H:%M:%S")]This script must be run as root!" >&2 >> $log_path
    exit 1
}


archive_path="/usr/syno/etc/certificate/_archive"
info_path="$archive_path/INFO"
cert_id_g=""
cert_storage_path=""
cert_enddate=""
cert_startdate=""
cert_subject=""
date_format="+%Y-%m-%d %H:%M:%S"

create_cert_storage_path() {
    if [[ ! -d "$cert_storage_path" ]]; then
        mkdir -p "$cert_storage_path"
    fi
}


copy_cert() {

	echo "Copying cert [$cert_source_path] -> [$cert_storage_path]..." >> $log_path
    cp "$cert_source_path/fullchain.pem" "$cert_storage_path/fullchain.pem"
    cp "$cert_source_path/fullchain.pem" "$cert_storage_path/cert.pem"
    cp "$cert_source_path/privkey.pem" "$cert_storage_path/privkey.pem"
	chmod 600 -R "$cert_storage_path"
}


verify_certificate() {
	local cert_path="$1"
    openssl x509 -noout -subject -in "$cert_path" | grep -q "$cert_domain"
}


check_cert_id_default(){
	local cert_id=""
	local input_id="$1"  input_id
	
	if [[ -n $cert_id_default_file ]]; then

		if [[ -n $input_id ]]; then
			echo "$input_id" > "$cert_id_default_file" >> $log_path
			chmod 666 "$cert_id_default_file"

			echo "Write cert_id_default [$input_id] successfully!" >> $log_path
		else

			if [[ -f $cert_id_default_file ]];then
				cert_id=$(cat "$cert_id_default_file")
				if [[ -n $cert_id ]];then
					cert_id_default="$cert_id"

					echo "Read cert_id_default [$cert_id_default] successfully!" >> $log_path
				else

					echo "Read cert_id_default [$cert_id_default_file] fail, file empty!" >&2 >> $log_path
				fi
			else

				echo "Read cert_id_default [$cert_id_default_file] fail, file not exist!" >&2 >> $log_path
			fi
		fi
	fi

}


make_cert_id() {
	local cert_id=""
	local tmp_info=""
    if [[ -n $1 ]]; then
        local input_id="$1"
		local cert_id="$input_id"
        if [[ ! -d $archive_path/$input_id ]]; then
            mkdir -p "$archive_path/$input_id"
        fi
    else
		check_cert_id_default
		if  [[ -n $cert_id_default ]]; then
			cert_id="$cert_id_default"
		else
			mkdir -p "$archive_path"
			cert_path=$(mktemp -d "$archive_path"/XXXXXX)
			
			cert_id="${cert_path##*/}"
			check_cert_id_default "$cert_id"
		fi
    fi
	tmp_info=$(mktemp)
	if [[ -s $info_path ]]; then
		jq --arg cert_id "$cert_id" '.[$cert_id] = { desc: "", services: [] }' < "$info_path" > "$tmp_info" \
		&& mv "$tmp_info" "$info_path"
	else
		jq -n --arg cert_id "$cert_id" '{ ($cert_id) : { desc: "", services: [] } }' > "$info_path"
	fi
    echo "cert_id set [$cert_id]." >> $log_path
	cert_id_g="$cert_id"
}


get() {
    local i="$1"
    local prop="$2"
    jq -r --arg cert_id "$cert_id_g" --arg i "$i" --arg prop "$prop" '.[$cert_id].services[$i|tonumber][$prop]' "$info_path"
}


reload_services() {
	echo "Reloading services for certificate $cert_domain..." >> $log_path
    local tls_profile_path="/usr/libexec/security-profile/tls-profile"
    services_length=$(jq -r --arg cert_id "$cert_id_g" '.[$cert_id].services|length' "$info_path")
    for (( i = 0; i < services_length; i++ )); do
        isPkg=$(get "$i" isPkg)
        subscriber=$(get "$i" subscriber)
        service=$(get "$i" service)
        if [[ $isPkg == true ]]; then
            exec_path="/usr/local/libexec/certificate.d/$subscriber"
            cert_path="/usr/local/etc/certificate/$subscriber/$service"
        else
            exec_path="/usr/libexec/certificate.d/$subscriber"
            cert_path="/usr/syno/etc/certificate/$subscriber/$service"

            if [[ -x $tls_profile_path/${subscriber}.sh ]]; then
                exec_path="$tls_profile_path/${subscriber}.sh"
            fi

            if [[ $subscriber == "system" && $service == "default" && -x $tls_profile_path/dsm.sh ]]; then
                exec_path="$tls_profile_path/dsm.sh"
            fi
        fi
        if ! diff -q "$cert_storage_path/cert.pem" "$cert_path/cert.pem" >/dev/null; then
            cp "$cert_storage_path/"{cert,chain,fullchain,privkey}.pem "$cert_path/"

            if [[ -x $exec_path ]]; then
                if [[ $subscriber == "system" && $service == "default" ]]; then "$exec_path"; else "$exec_path" "$service"; fi
            fi
        fi
    done
}


reload_nginx() {
    echo "Reloading nginx service..." >> $log_path
    /usr/syno/bin/synow3tool --gen-all

    if [[ -x /usr/syno/bin/synosystemctl ]]; then
        if /usr/syno/bin/synow3tool --nginx=is-running > /dev/null 2>&1; then
            /usr/syno/bin/synosystemctl reload --no-block nginx
        fi
    elif [[ -x /usr/syno/sbin/synoservice ]]; then
        if /usr/syno/sbin/synoservice --status nginx > /dev/null 2>&1; then
            /usr/syno/bin/synow3tool --gen-nginx-tmp && /usr/syno/sbin/synoservice --reload nginx
        fi
    else
        echo "synosystemctl or synoservice not found!" >&2 >> $log_path

    fi
}


update_cert_info(){
	local cert_path="$1"
	cert_subject=$(openssl x509 -in "$cert_path" -noout -ext subjectAltName | grep DNS: | sed 's/DNS://g'| tr -d '[:space:]')
	cert_startdate=$(date -d "$(openssl x509 -in "$cert_path" -noout -startdate | cut -d= -f2)" "$date_format")
	cert_enddate=$(date -d "$(openssl x509 -in "$cert_path" -noout -enddate | cut -d= -f2)" "$date_format")
}


compare_cert() {
    used_cert_path="$cert_storage_path/fullchain.pem"
    tbu_cert_path="$cert_source_path/fullchain.pem"
	
	
	if [[ ! -f $used_cert_path ]]; then
		return 0
	fi
	
	
	current_ts=$(date +%s)
	used_cert_start_ts=$(date -d "$(openssl x509 -in "$used_cert_path" -noout -startdate | cut -d= -f2)" +%s)
	used_cert_end_ts=$(date -d "$(openssl x509 -in "$used_cert_path" -noout -enddate | cut -d= -f2)" +%s)
	used_cert_end_date=$(date -d "$(openssl x509 -in "$used_cert_path" -noout -enddate | cut -d= -f2)" "$date_format")
	tbu_cert_start_ts=$(date -d "$(openssl x509 -in "$tbu_cert_path" -noout -startdate | cut -d= -f2)" +%s)
	tbu_cert_end_ts=$(date -d "$(openssl x509 -in "$tbu_cert_path" -noout -enddate | cut -d= -f2)" +%s)
	
	
	if [[ $current_ts -ge $tbu_cert_start_ts && $current_ts -le $tbu_cert_end_ts ]]; then
		if [[ $used_cert_end_ts -lt $tbu_cert_end_ts ]]; then
			return 0
		else
			update_cert_info "$tbu_cert_path"

			echo "Certificate subject is [$cert_subject] matched, but its enddate [$cert_enddate] <= used_cert_enddate [$used_cert_end_date]!" >&2 >> $log_path
			return 1
		fi
	else

		echo "Certificate subject is [$cert_subject] matched, but its validity period: [$cert_startdate ~ $cert_enddate] is expired!" >&2 >> $log_path
		return 1
	fi
}


cert_path_g="$cert_source_path/fullchain.pem"
if $(verify_certificate "$cert_path_g"); then

	echo "Certificate from [$cert_source_path] matches the domain [$cert_domain]!" >> $log_path
    make_cert_id "$cert_id_default"
	cert_storage_path="$archive_path/$cert_id_g"
    create_cert_storage_path
	if compare_cert; then
		copy_cert
		reload_services
		reload_nginx
		update_cert_info "$cert_path_g"
		echo "Certificate subject is [$cert_subject] matched and its validity period: [$cert_startdate ~ $cert_enddate]." >> $log_path
		echo "[$(date +"%Y-%m-%d %H:%M:%S")]Certificate [$cert_domain] renewal process done!" >> $log_path
		exit 0
	else
		echo "[$(date +"%Y-%m-%d %H:%M:%S")]Certificate [$cert_domain] renewal process quit!" >> $log_path
		exit 2
	fi
else

	echo "Certificate from [$cert_source_path] does not match the domain [$cert_domain]!" >&2 >> $log_path
	echo "[$(date +"%Y-%m-%d %H:%M:%S")]Certificate [$cert_domain] renewal process quit!" >&2 >> $log_path
    exit 1
fi
