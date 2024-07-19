#!/bin/bash

##  v2.0

##  'HELLO FELLOW EMUSER!'
##  This script was developed for our devs with bash-capable OSes that want
##  an easy way to update the local database to test friday afternoon code
##  that no one likes to.
##
##  '~DON'T FORGET~'
##  To set up the config file so that the script knows where to get the files
##  and access the mysql to import the db.
##
##  CHANGELOG:
##  Created in 25/09/2019 by Leonardo Waltrick Ronconi(aka Greg).
##  Rewritten with added features in 05/07/2024 by the author.

################################# Functions ###############################
_changeColor() {
	echo -ne "${1}"
}

_neutralFormat() {
	echo -ne "$(tput sgr0)"
}

_clearLine() {
	echo -ne "\033[F\033[J"
}

_echo() {
	local text=${1:-''}
	local timestamp=${2:-false}
	local color=${3:-$primaryColor}
	local time=""
	[ "$timestamp" = true ] && printf -v time '[%s] ' "$(date +"%T")"
	echo -e "$(_changeColor $color)$time$text$(_neutralFormat)"
}

_triggerWarning() {
	local warning=${1}
	[ "$warning" != "0" ] && _echo "Warning: $warning" false $warningColor
}

_triggerError() {
	local error=${1}
	[ "$error" != "0" ] && _echo "${bold}$error" false $errorColor && _echo && exit
}

_formatSize() {
	local value=${1}
	local width=${2}
	local suffix=${3}
	local precision=$(( width - 5 ))
	local text=$(numfmt --to=iec-i --suffix=${suffix} --format="%.${precision}f" ${value})
	while [ ${#text} -gt $width ]
	do
		(( precision-- ))
		text=$(numfmt --to=iec-i --suffix=${suffix} --format="%.${precision}f" ${value})
	done
	printf "%${width}s" "$text"
}

_formatSeconds() {
	local h=$(( ${1}/3600 ))
	local m=$(( (${1}%3600)/60 ))
	local s=$(( ${1}%60 ))
	if (( ${#h} > 1 )) 
	then
		printf "${longETA7LetterText}\n"
	else
		printf "%01d:%02d:%02d\n" $h $m $s
	fi
}

_progressBar() {
    local currentSize=${1:-0}
    local lastSize=${2:-0}
    local totalSize=${3:-0}
    local currentSeconds=${4:-0}
    local intervalSeconds=${5:-1}
    local percent=$(( currentSize*100/totalSize ))
    local datarate=$(( (currentSize - lastSize)/intervalSeconds ))
    local eta=""
    local offset=46
    [ "$currentSize" == "$totalSize" ] && offset=47
    (( "$datarate" > 0 )) && [ "$currentSize" != "$totalSize" ] && eta="ETA $(_formatSeconds $(( (totalSize - currentSize)/datarate )) )"
    local maxwidth=$(( $COLUMNS - $offset ))	
    local chars=$(( percent * maxwidth / 100 ))
    printf -v complete '%0*.*d' '' "$chars" ''
    printf -v remain '%0*.*d' '' "$(( maxwidth - chars ))" ''
    local complete=${complete//0/"="}
    [ -n "$complete" ] && complete=${complete%?}">"
    local remain=${remain//0/" "}
    printf '%s %s %s [%s%s] %s%% %s\r' "$(_formatSize $currentSize 7 "B")" "$(_formatSeconds $currentSeconds)" "[$(_formatSize $datarate 9 "B/s")]" "$complete" "$remain" "$(numfmt --format="%2.0f" ${percent})" "${eta:="$(printf '%11s' "")"}"
}

_setSSHPASS() {
	[ -n "$(printenv SSHPASS)" ] && return 0
	[ -n "${serverPassword}" ] && SSHPASS="${serverPassword}" && export SSHPASS && return 0
	local passwdPrompt="${serverUser}@${serverAddress}'s password:"
	_echo "$passwdPrompt"
	echo -ne "\033[1A\033[${#passwdPrompt}C"
	read -s SSHPASS
	export SSHPASS
	sshpass -e ssh -q ${serverUser}@${serverAddress} exit
	local errorCode="$?"
	[ "$errorCode" == "5" ] && _triggerError "${bold} ${incorrectPasswd}${notBold}"
	[ "$errorCode" != "0" ] && _triggerError "${bold} ${failText}${notBold}"
	_echo
	_clearLine && _neutralFormat
}

_unsetSSHPASS() {
	[ "$persistentServerPassword" -ne "1" ] || [ -n "${serverPassword}" ] && unset SSHPASS
}

_deleteOldZIPFiles() {
	#to be added in a future update
	_echo
}

_deleteOldSQLFiles() {
	#to be added in a future update
	_echo
}

_removeFileIfCorrupted(){
	local filename=${1}
	local fileRealSize=${2}
	[[ "$fileRealSize" -eq "0" ]] && _triggerWarning "$filename não verificado!" && return 1
	[ -s "${filename}" ] && [ "$(stat -c%s "${filename}")" != "${fileRealSize}" ] && _echo "$removingCorruptedText..." $secondaryColor && rm ${filename}
}

_getServerFilesize(){
	local filename=${1}
	local filesizeCommand="sshpass -e ssh ${serverUser}@${serverAddress} stat -c%s ${serverDirectory}/${filename}"
	_setSSHPASS
	globalFilesize="$($filesizeCommand 2> /dev/null)"
	_unsetSSHPASS
}

_downloadFile() {
	local filename=${1}
	local serverFilesize=${2}
	local scpCommand="sshpass -e scp ${serverUser}@${serverAddress}:${serverDirectory}/$filename $filename"
	[ -n "${enableVerbose+x}" ] && _echo "$scpCommand" true || _echo "${bold}$downloadingText ${notBold}$filename" true
	[[ "$serverFilesize" -eq "0" ]] && _triggerError "server file size equals 0" && return 1
	_setSSHPASS
	$scpCommand 2>&1 > /dev/null &
	_unsetSSHPASS
	_changeColor $secondaryColor
	SECONDS=0
	local downloadReady=0 clientFilesize=0 oldClientFilesize=0
	while [ "$downloadReady" -eq 0 ]
	do
		[ ! -f "$filename" ] && sleep 0.5 && continue
		oldClientFilesize=$clientFilesize
		clientFilesize=$(stat -c%s "$filename")
		_progressBar "$clientFilesize" "$oldClientFilesize" "$serverFilesize" $SECONDS
		sleep 1;
		[ "$clientFilesize" == "$serverFilesize" ] && downloadReady=1
	done
	_echo
	[ "$clearProgressBar" -eq "1" ] && _clearLine
	_neutralFormat
	return 0
}

_unzipFile() {
	local zipFilename=${1}
	local sqlFilename=${2}
	local unzipCommand="unzip -o $zipFilename $sqlFilename"
	[ -n "${enableVerbose+x}" ] && _echo "$unzipCommand" true || _echo "${bold}$unzipingText ${notBold}$sqlFilename" true
	$unzipCommand 2>&1 > /dev/null
	return 0
}

_importSQL() {
	local filename=${1}
	credentials=();
	[ -n "$localMySQLUser" ] && credentials+=("-u${localMySQLUser}")
	[ -n "$localMySQLPassword" ] && credentials+=("-p${localMySQLPassword}")
	[ -n "${enableVerbose+x}" ] && _echo "mysql "${credentials[@]}" < "${filename}"" true || _echo "${bold}${importingText} ${notBold}${filename}" true
	_changeColor $secondaryColor
	pv "${filename}" | mysql "${credentials[@]}";
	[ "$clearProgressBar" -eq "1" ] && _clearLine
	_neutralFormat
	return 0
}

################################ Initialize ###############################

while getopts d:m:y:t:zv flag
do
	case "${flag}" in
		d) selectedDay=${OPTARG};;
		m) selectedMonth=${OPTARG};;
		y) selectedYear=${OPTARG};;
		t) selectedTime=${OPTARG};;
		z) downloadZip=1;;
		v) enableVerbose=1;;
	esac
done

shift $((OPTIND - 1))

parameters=("serverDirectory" "serverAddress" "serverUser" "serverPassword" "persistentServerPassword" "clearProgressBar" "localMySQLUser" "localMySQLPassword" "deleteOldSQL" "deleteOldZIP")
format=("bold" "notBold" "primaryColor" "secondaryColor" "warningColor" "errorColor")

configs=( "${parameters[@]}" "${format[@]}")

_echo

for config in ${configs[@]}; do
	val=$(grep -E "^$config=" -m 1 b.cfg 2>/dev/null || echo "VAR=");
	[ -n "${enableVerbose+x}" -a ${config} != "serverPassword" ] && echo "${val}"
	declare $config="$(echo $val| head -n 1 | cut -d '=' -f 2-)";
done

hour=$(date +%H)
[ -z "$selectedDay" ] && selectedDay=$(date +%d) && [ "$hour" -lt 02 ] && selectedDay=$(date --date="Yesterday" +%d)
[ -z "$selectedMonth" ] && selectedMonth=$(date +%m) && [ "$hour" -lt 02 ] && selectedMonth=$(date --date="Yesterday" +%m)
[ -z "$selectedYear" ] && selectedYear=$(date +%Y) && [ "$hour" -lt 02 ] && selectedYear=$(date --date="Yesterday" +%Y)
[ -z "$selectedTime" ] && selectedTime=0201 && [ "$hour" -ge 12 ] || [ "$hour" -lt 02 ] && selectedTime=1200

directory=$(pwd)

greetingText="Olá"
downloadingText="Baixando"
removingCorruptedText="Removendo arquivo corrompido"
unzipingText="Inflando"
importingText="Importando"
longETA7LetterText="forever"
failText="Falha Desconhecida!"
interruptText="Interrompendo script"
incorrectPasswd="Senha Incorreta!"
invalidIDText="não é um valor válido!"

trap "unset SSHPASS && _echo && _echo \"$interruptText\"... && _echo && sleep 0.2 && _neutralFormat && exit" INT

################################### Main ##################################

[ -z "${enableVerbose+x}" ] && _echo "${greetingText} ${bold}$(whoami)!${notBold}" || _echo

# To be added in a future update
#[ "$deleteOldZIP" -eq "1" ] && _deleteOldZIPFiles
#[ "$deleteOldSQL" -eq "1" ] && _deleteOldSQLFiles

zipFilename="${selectedYear}${selectedMonth}${selectedDay}_${selectedTime}.zip"
if [ -e "$zipFilename" ] || [ -n "${downloadZip+x}" ]
then
	_getServerFilesize $zipFilename
	zipFilesize="$globalFilesize"
	_removeFileIfCorrupted $zipFilename $zipFilesize
fi

re='^[0-9]+$'
while [ -n "${1}" ]
do
	id=${1} && shift

	if ! [[ "$id" =~ $re ]] && [ "$id" != "sys" ]; then
		_triggerWarning "$id $invalidIDText" && continue
	fi

	basename="emusys_$id"
	[ "$id" == "sys" ] && basename="sysemusys"
	
	sqlFilename="${basename}_${selectedYear}${selectedMonth}${selectedDay}_${selectedTime}.sql"
	_getServerFilesize $sqlFilename
	sqlFilesize="$globalFilesize"
	_removeFileIfCorrupted $sqlFilename $sqlFilesize

	[ ! -e "$sqlFilename" ] && [ ! -e "$zipFilename" ] && [ -n "${downloadZip+x}" ] && _downloadFile $zipFilename $zipFilesize
	[ -e "$zipFilename" ] && _unzipFile $zipFilename $sqlFilename
	[ ! -e "$sqlFilename" ] && _downloadFile $sqlFilename $sqlFilesize
	_importSQL $sqlFilename
	[ -e "$zipFilename" ] && rm $sqlFilename
done

_echo "Feito!" true
_echo
