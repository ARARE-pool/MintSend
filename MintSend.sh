#!/bin/bash


paymentSignKeyPath=/opt/cardano/cnode/priv/wallet/name/payment.skey   # PATH TO PAYMENT SKEY FILE (SelfAddr)
policySignKeyPath=policy/policy.skey   # PATH TO POLICY SKEY FILE
scriptPath=policy/policy.script  # PATH TO POLICY SCRIPT FILE
protocol=policy/protocol.json    # PATH TO PROTOCOL FILE
metadata=nft_meta.json      # DO NOT CHANGE
SelfAddr=[YOUR WALLET ADDR] # Your wallet address (will pay the fees + minADA)
TTL=[TTL HERE]              # Your script TTL
POLICYID=[POLICY ID HERE]   # Your policy-id

minADA=1444443 # min ADA send among with asset (check out calculator https://mantis.functionally.io/how-to/min-ada-value/)


#####################################################
###                                               ###
###           DONT EDIT BELOW THIS PART           ###
###                                               ###
#####################################################



########## Global tasks ###########################################

myExit() {
	exit
}

# Command     : getBalance [address]
# Description : check balance for provided address
# Parameters  : address  >  the wallet address to query
# Return      : populates associative arrays ${assets[]} & ${policyIDs[]}
getBalance() {
  declare -gA utxos=(); declare -gA assets=(); declare -gA policyIDs=()
  assets["lovelace"]=0; utxo_cnt=0
  asset_name_maxlen=5; asset_amount_maxlen=12
  tx_in=""
  
  if [[ -z ${KOIOS_API} ]]; then
    if [[ -z ${1} ]] || ! utxo_raw=$(${CCLI} query utxo ${NETWORK_IDENTIFIER} --address "${1}"); then return 1; fi
    [[ -z ${utxo_raw} ]] && return
    
    while IFS= read -r line; do
      IFS=' ' read -ra utxo_entry <<< "${line}"
      [[ ${#utxo_entry[@]} -lt 4 ]] && continue
      ((utxo_cnt++))
      tx_in+=" --tx-in ${utxo_entry[0]}#${utxo_entry[1]}"
      if [[ ${utxo_entry[3]} = "lovelace" ]]; then
        utxos["${utxo_entry[0]}#${utxo_entry[1]}. Ada"]=${utxo_entry[2]} # Space added before 'Ada' for sort to place it first
        assets["lovelace"]=$(( ${assets["lovelace"]:-0} + utxo_entry[2] ))
        idx=5
      else
        utxos["${utxo_entry[0]}#${utxo_entry[1]}. Ada"]=0 # Space added before 'Ada' for sort to place it first
        assets["lovelace"]=0
        idx=2
      fi
      if [[ ${#utxo_entry[@]} -gt "${idx}" ]]; then
        while [[ ${#utxo_entry[@]} -gt ${idx} ]]; do
          asset_amount=${utxo_entry[${idx}]}
          if ! isNumber "${asset_amount}"; then break; fi
          asset_hash_name="${utxo_entry[$((idx+1))]}"
          IFS='.' read -ra asset <<< "${asset_hash_name}"
          policyIDs["${asset[0]}"]=1
          [[ ${#asset[@]} -eq 2 && ${#asset[1]} -gt ${asset_name_maxlen} ]] && asset_name_maxlen=${#asset[1]}
          asset_amount_fmt="$(formatAsset ${asset_amount})"
          [[ ${#asset_amount_fmt} -gt ${asset_amount_maxlen} ]] && asset_amount_maxlen=${#asset_amount_fmt}
          assets["${asset_hash_name}"]=$(( ${assets["${asset_hash_name}"]:-0} + asset_amount ))
          utxos["${utxo_entry[0]}#${utxo_entry[1]}.${asset_hash_name}"]=${asset_amount}
          idx=$(( idx + 3 ))
        done
      fi
    done <<< "${utxo_raw}"
  else
    println ACTION "curl -sSL -f -d _address=${1} ${KOIOS_API}/address_info"
    ! addr_info=$(curl -sSL -f -d _address=${1} ${KOIOS_API}/address_info 2>&1) && return 1
    [[ ${addr_info} = '[]' || $(jq -r '.[0].balance //0' <<< ${addr_info}) -eq 0 ]] && return

    assets["lovelace"]=$(jq -r .[0].balance <<< ${addr_info})

    if [[ -n $(jq -r '.[0].utxo_set //empty' <<< "${addr_info}") ]]; then
      for utxo in $(jq -r '.[0].utxo_set[] | @base64' <<< "${addr_info}"); do
        ((utxo_cnt++))
        utxo_tsv=$(jq -r '[
        .tx_hash,
        .tx_index,
        .value,
        (.asset_list|@base64)
        ] | @tsv' <<< "$(base64 -d <<< ${utxo})")
        read -ra utxo_entry <<< ${utxo_tsv}
        utxos["${utxo_entry[0]}#${utxo_entry[1]}. Ada"]=${utxo_entry[2]} # Space added before 'Ada' for sort to place it first
        tx_in+=" --tx-in ${utxo_entry[0]}#${utxo_entry[1]}"
        asset_list=$(base64 -d <<< ${utxo_entry[3]})
        if [[ ${asset_list} != '[]' ]]; then
          for asset in $(jq -r '.[] | @base64' <<< "${asset_list}"); do
            asset_tsv=$(jq -r '[
            .policy_id,
            (.asset_name|select(. != "") //"-"),
            .quantity
            ] | @tsv' <<< "$(base64 -d <<< ${asset})")
            read -ra asset_entry <<< ${asset_tsv}
            [[ ${asset_entry[1]} = '-' ]] && asset_entry[1]=""
            policyIDs["${asset_entry[0]}"]=1
            [[ ${#asset_entry[1]} -gt ${asset_name_maxlen} ]] && asset_name_maxlen=${#asset_entry[1]}
            asset_amount_fmt="$(formatAsset ${asset_entry[2]})"
            [[ ${#asset_amount_fmt} -gt ${asset_amount_maxlen} ]] && asset_amount_maxlen=${#asset_amount_fmt}
            asset_hash_name="${asset_entry[0]}.${asset_entry[1]}"
            assets["${asset_entry[0]}.${asset_entry[1]}"]=$(( ${assets["${asset_hash_name}"]:-0} + asset_entry[2] ))
            utxos["${utxo_entry[0]}#${utxo_entry[1]}.${asset_hash_name}"]=${asset_entry[2]}
          done
        fi
      done
    fi
  fi

  [[ ${asset_name_maxlen} -ne 5 ]] && asset_name_maxlen=$(( asset_name_maxlen / 2 ))
  lovelace_fmt="$(formatLovelace ${assets["lovelace"]})"
  [[ ${#lovelace_fmt} -gt ${asset_amount_maxlen} ]] && asset_amount_maxlen=${#lovelace_fmt}
}


# Command     : getAnswerAnyCust [variable name] [log] [question]
# Description : wrapper function for getAnswerAny() in env to read input from stdin 
#               and save response into provided variable name while also logging response
# Parameters  : variable name  >  the name of the variable to save users response into
#             : log            >  [true|false] log question (default: true)
#             : question       >  what to ask user to input
getAnswerAnyCust() {
  sleep 0.1 # hack, sleep 100ms before asking question to preserve order
  var_name=$1
  shift
  local log_question=false
  if [[ $1 =~ true|false ]]; then
    [[ $1 = false ]] && log_question=false
    shift
  fi
  getAnswerAny "${var_name}" "$*"
  [[ ${log_question} = true ]]
}



PARENT="$(dirname $0)"
if [[ ! -f "${PARENT}"/env ]]; then
  echo -e "\nCommon env file missing: ${PARENT}/env"
  echo -e "This is a mandatory prerequisite, please install with prereqs.sh or manually download from GitHub\n"
  myExit 1
fi



. "${PARENT}"/env


echo "  __   ____   __   ____  ____     "
echo " / _\ (  _ \ / _\ (  _ \(  __)    "
echo "/    \ )   //    \ )   / ) _)     "
echo "\_/\_/(__\_)\_/\_/(__\_)(____)    " && sleep 0.4
echo " ____  ____  __   __ _  ____      "
echo "/ ___)(_  _)/ _\ (  / )(  __)     "
echo "\___ \  )( /    \ )  (  ) _)      "
echo "(____/ (__)\_/\_/(__\_)(____)     " && sleep 0.4
echo " ____   __    __   __             "
echo "(  _ \ /  \  /  \ (  )            "
echo " ) __/(  O )(  O )/ (_/\          "
echo "(__)   \__/  \__/ \____/          " && sleep 0.4
echo " __ _  ____  ____                 "
echo "(  ( \(  __)(_  _)                "
echo "/    / ) _)   )(                  "
echo "\_)__)(__)   (__)                 " && sleep 0.4
echo " ____   ___  ____  __  ____  ____ "
echo "/ ___) / __)(  _ \(  )(  _ \(_  _)"
echo "\___ \( (__  )   / )(  ) __/  )(  "
echo "(____/ \___)(__\_)(__)(__)   (__) " && sleep 0.4


echo -e "\n\nWelcome to ARARE NFT script" && sleep 0.1
if { getAnswer "Would you like to start?"; }; then sleep 0.4
else echo -e "${FG_LBLUE}Bye Bye${NC}"
	 sleep 0.4 && myExit
fi

export CARDANO_NODE_SOCKET_PATH=${CNODE_HOME}/sockets/node0.socket


# Metadata
# ====================
Assnum=$(head -n 1 numnum.txt)
ASSETname=ARAREISPO${Assnum}
nameHEX=$(echo "${ASSETname}" | tr -d '\n' | xxd -p)
echo "{\"721\":{\"${POLICYID}\":{\"${ASSETname}\":{\"description\":\"Whoaw you received an NFT suggesting to join ARARE Stake pool\",\"details\":\"ARARE delegators earn \$INDY and \$ZIBER\",\"running ispos\":[\"Earn \$INDY airdrop\",\"Earn \$ZIBER - Play-2-Earn NFT Game\"],\"files\":[{\"mediaType\":\"image/png\",\"name\":\"ARARE ISPOs\",\"src\":\"ipfs://QmPwfN3rNQZckC6ULsz3sMPvBtdWYwzgmJdu9bY758z3jo\"}],\"image\":\"ipfs://QmPwfN3rNQZckC6ULsz3sMPvBtdWYwzgmJdu9bY758z3jo\",\"mediaType\":\"image/png\",\"name\":\"ARARE ISPOs\",\"website\":\"https://arare.io\"}}}}"  > "nft_meta.json"

# ====================


# Print queue Info
# ====================
echo ""
echo "Asset in queue" && sleep 0.2
echo "-----------------------------------------------" && sleep 0.2
echo -e "Asset in queue            : ${FG_LBLUE}${ASSETname}${NC}" && sleep 0.2
echo "Name HEX                  : ${nameHEX}" && sleep 0.2
echo "PolicyID                  : $POLICYID" && sleep 0.2
echo "TTL                       : ${TTL}" && sleep 0.2


if { getAnswer "Would you like to send this asset?"; }; then sleep 0.4
else echo -e "${FG_LBLUE}Bye Bye${NC}"
   sleep 0.4 && myExit
fi



# Balance
# ====================
echo -e ""
echo -e "Checking balance..."

getBalance ${SelfAddr}

echo -e "Balance is                : ${FG_LBLUE}${assets[lovelace]} lovelace${NC}" && sleep 0.4

# sleep 0.5
# echo -e ""
# echo -e "utxo                   : ${utxo_entry[1]}"
# echo -e "tx-in                  : ${tx_in}"
# echo -e "Asset in queue         : ${ASSETname}"
# echo -e ""
# ====================





# get Address
# ====================
getAnswerAnyCust d_addr "Receiving Address"
# echo $d_addr
# ====================




amountToSendUser=${minADA}
amountToSendSelf=$((${assets[lovelace]} - ${amountToSendUser}))





# Tx Build
# ====================
echo -e ""
echo "-------------------------------"
echo " Building tx... :  $(date +%T)"
echo "-------------------------------"
echo "" && sleep 0.4





EXPIRE=${TTL}

cardano-cli transaction build-raw \
    --fee 0 \
    ${tx_in} \
    --tx-out ${d_addr}+${amountToSendUser}+"1 $POLICYID.${nameHEX}" \
    --tx-out ${SelfAddr}+${amountToSendSelf} \
    --mint "1 $POLICYID.${nameHEX}" \
    --minting-script-file $scriptPath \
    --metadata-json-file ${metadata} \
    --invalid-hereafter $EXPIRE \
    --out-file matx.raw

fee=$(cardano-cli transaction calculate-min-fee \
  --tx-body-file matx.raw \
  --tx-in-count 1 \
  --tx-out-count 2 \
  --mainnet \
  --witness-count 2 \
  --byron-witness-count 0 \
  --protocol-params-file ${protocol} | awk '{ print $1 }')



# Print Info
# ====================
# echo "Name HEX                  : ${nameHEX}" && sleep 0.2
# echo "PolicyID                  : $POLICYID" && sleep 0.2
# echo -e "Asset to send             : ${FG_LBLUE}${ASSETname}${NC}" && sleep 0.2
# echo "TTL                       : ${TTL}" && sleep 0.2
# echo "" && sleep 0.4
echo "Transaction info" && sleep 0.2
echo "-----------------------------------------------" && sleep 0.2
echo "TxIn                      : ${tx_in}" && sleep 0.2
echo "Destination Address       : ${d_addr}" && sleep 0.2
echo "Amount send with the NFT  : ${amountToSendUser}" && sleep 0.2
echo "Fee                       : ${fee}" && sleep 0.2
echo -e "Amount left in the wallet : ${FG_LBLUE}${amountToSendSelf} lovelace${NC}" && sleep 0.2
echo ""


fee=${fee%" Lovelace"}
amountToSendSelf=$((${amountToSendSelf} - ${fee}))

cardano-cli transaction build-raw \
    --fee ${fee} \
    ${tx_in} \
    --tx-out ${d_addr}+${amountToSendUser}+"1 $POLICYID.${nameHEX}" \
    --tx-out ${SelfAddr}+${amountToSendSelf} \
    --mint "1 $POLICYID.${nameHEX}" \
    --minting-script-file $scriptPath \
    --metadata-json-file ${metadata} \
    --invalid-hereafter $EXPIRE \
    --out-file matx.raw
# ====================


if { getAnswer "Would you like to Sign & Submit the transaction?"; }; then sleep 0.4
else echo -e "${FG_LBLUE}Bye Bye${NC}"
   sleep 0.4 && myExit
fi



# Tx Sign & Submit
# ====================

cardano-cli transaction sign \
  --signing-key-file $paymentSignKeyPath \
  --signing-key-file $policySignKeyPath \
  --tx-body-file matx.raw \
  --out-file matx.signed \
  --mainnet

if ! cardano-cli transaction submit --tx-file matx.signed --mainnet; then
  echo -e ""
  echo "----------------------"
  echo " Error :  $(date +%T)"
  echo "----------------------"
  myExit 1
fi

echo -e ""
echo -e "Transaction Submitted     :  ${FG_LBLUE}$(date +%T)${NC}"
	 

# Remove lines in number file
# ====================
tail -n +2 numnum.txt > tmpNum.txt && mv tmpNum.txt numnum.txt


# ====================
