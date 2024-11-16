#!/bin/bash

# Fungsi untuk mengvalidasi alamat IPv4 dan FQDN
validate_hex() {
  if [[ ! "$1" =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    echo "The private key seems invalid, exiting ..."
    exit 1
  fi
}

validate_address() {
  if [[ ! "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "Invalid wallet address, exiting!"
    exit 1
  fi
}

validate_port() {
  if [[ ! "$1" =~ ^[0-9]+$ ]] || [ "$1" -le 1024 ] || [ "$1" -ge 65535 ]; then
    echo "Invalid port number, it must be between 1024 and 65535."
    exit 1
  fi
}

validate_ip_or_fqdn() {
  local input=$1

  if [[ "$input" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    IFS='.' read -r -a octets <<< "$input"
    for octet in "${octets[@]}"; do
      if (( octet < 0 || octet > 255 )); then
        echo "Invalid IPv4 address. Each octet must be between 0 and 255."
        return 1
      fi
    done

    if [[ "$input" =~ ^10\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^192\.168\.|^169\.254\.|^100\.64\.|^198\.51\.100\.|^203\.0\.113\.|^224\.|^240\. ]]; then
      echo "The provided IP address belongs to a private or non-routable range and might not be accessible from other nodes."
      return 1
    fi
  elif [[ "$input" =~ ^[a-zA-Z0-9.-]+$ ]]; then
    return 0
  else
    echo "Invalid input, must be a valid IPv4 address or FQDN."
    return 1
  fi

  return 0
}

# Fungsi untuk membuat folder dan menjalankan skrip docker-compose di setiap folder
create_folders_and_compose() {
  local num_folders=$1
  local starts_from=$2

  for ((i = $starts_from; i <= num_folders+$starts_from-1; i++)); do
    folder_name="$i"
    echo "Creating folder: $folder_name"
    mkdir -p "$folder_name"
    cd "$folder_name" || exit

    echo "Generating Docker Compose file in $folder_name"

    # Generate private key
    echo "Generating Private Key, please wait..."
    output=$(head -c 32 /dev/urandom | xxd -p | tr -d '\n' | awk '{print "0x" $0}')
    PRIVATE_KEY=$(echo "$output")
    echo -e "Generated Private Key: \e[1;31m$PRIVATE_KEY\e[0m"
    # Simpan private key ke dalam file
    echo "$PRIVATE_KEY" > private_key.txt
    echo "Private key saved to private_key.txt"

    validate_hex "$PRIVATE_KEY"

    read -p "Please provide the wallet address to be added as Ocean Node admin account: " ALLOWED_ADMINS
    validate_address "$ALLOWED_ADMINS"

    HTTP_API_PORT=$((8000 + i))
    validate_port "$HTTP_API_PORT"

    P2P_ipV4BindTcpPort=$((9000 + i + (i*10)))
    validate_port "$P2P_ipV4BindTcpPort"

    P2P_ipV4BindWsPort=$((9001 + i + (i*10)))
    validate_port "$P2P_ipV4BindWsPort"

    P2P_ipV6BindTcpPort=$((9002 + i + (i*10)))
    validate_port "$P2P_ipV6BindTcpPort"

    P2P_ipV6BindWsPort=$((9003 + i + (i*10)))
    validate_port "$P2P_ipV6BindWsPort"

    Typesense_Port=$((8108 + i))

    read -p "Provide the public IPv4 address or FQDN where this node will be accessible: " P2P_ANNOUNCE_ADDRESS

    if [ -n "$P2P_ANNOUNCE_ADDRESS" ]; then
      validate_ip_or_fqdn "$P2P_ANNOUNCE_ADDRESS"
      if [ $? -ne 0 ]; then
        echo "Invalid address. Exiting!"
        exit 1
      fi

      if [[ "$P2P_ANNOUNCE_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # IPv4
        P2P_ANNOUNCE_ADDRESSES='["/ip4/'$P2P_ANNOUNCE_ADDRESS'/tcp/'$P2P_ipV4BindTcpPort'", "/ip4/'$P2P_ANNOUNCE_ADDRESS'/ws/tcp/'$P2P_ipV4BindWsPort'"]'
      elif [[ "$P2P_ANNOUNCE_ADDRESS" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        # FQDN
        P2P_ANNOUNCE_ADDRESSES='["/dns4/'$P2P_ANNOUNCE_ADDRESS'/tcp/'$P2P_ipV4BindTcpPort'", "/dns4/'$P2P_ANNOUNCE_ADDRESS'/ws/tcp/'$P2P_ipV4BindWsPort'"]'
      fi
    else
      P2P_ANNOUNCE_ADDRESSES=''
      echo "No input provided, the Ocean Node might not be accessible from other nodes."
    fi

    cat <<EOF > docker-compose.yml
services:
  ocean-node:
    image: oceanprotocol/ocean-node:latest
    pull_policy: always
    container_name: ocean-node-$i
    restart: on-failure
    ports:
      - "$HTTP_API_PORT:$HTTP_API_PORT"
      - "$P2P_ipV4BindTcpPort:$P2P_ipV4BindTcpPort"
      - "$P2P_ipV4BindWsPort:$P2P_ipV4BindWsPort"
      - "$P2P_ipV6BindTcpPort:$P2P_ipV6BindTcpPort"
      - "$P2P_ipV6BindWsPort:$P2P_ipV6BindWsPort"
    environment:
      PRIVATE_KEY: '$PRIVATE_KEY'
      RPCS: '{"1":{"rpc":"https://ethereum-rpc.publicnode.com","fallbackRPCs":["https://rpc.ankr.com/eth","https://1rpc.io/eth","https://eth.api.onfinality.io/public"],"chainId":1,"network":"mainnet","chunkSize":100},"10":{"rpc":"https://mainnet.optimism.io","fallbackRPCs":["https://optimism-mainnet.public.blastapi.io","https://rpc.ankr.com/optimism","https://optimism-rpc.publicnode.com"],"chainId":10,"network":"optimism","chunkSize":100},"137":{"rpc":"https://polygon-rpc.com/","fallbackRPCs":["https://polygon-mainnet.public.blastapi.io","https://1rpc.io/matic","https://rpc.ankr.com/polygon"],"chainId":137,"network":"polygon","chunkSize":100},"23294":{"rpc":"https://sapphire.oasis.io","fallbackRPCs":["https://1rpc.io/oasis/sapphire"],"chainId":23294,"network":"sapphire","chunkSize":100},"23295":{"rpc":"https://testnet.sapphire.oasis.io","chainId":23295,"network":"sapphire-testnet","chunkSize":100},"11155111":{"rpc":"https://eth-sepolia.public.blastapi.io","fallbackRPCs":["https://1rpc.io/sepolia","https://eth-sepolia.g.alchemy.com/v2/demo"],"chainId":11155111,"network":"sepolia","chunkSize":100},"11155420":{"rpc":"https://sepolia.optimism.io","fallbackRPCs":["https://endpoints.omniatech.io/v1/op/sepolia/public","https://optimism-sepolia.blockpi.network/v1/rpc/public"],"chainId":11155420,"network":"optimism-sepolia","chunkSize":100}}'
      DB_URL: 'http://typesense:$Typesense_Port/?apiKey=xyz'
      IPFS_GATEWAY: 'https://ipfs.io/'
      ARWEAVE_GATEWAY: 'https://arweave.net/'
      INTERFACES: '["HTTP","P2P"]'
      ALLOWED_ADMINS: '["$ALLOWED_ADMINS"]'
      DASHBOARD: 'true'
      HTTP_API_PORT: '$HTTP_API_PORT'
      P2P_ENABLE_IPV4: 'true'
      P2P_ENABLE_IPV6: 'false'
      P2P_ipV4BindAddress: '0.0.0.0'
      P2P_ipV4BindTcpPort: '$P2P_ipV4BindTcpPort'
      P2P_ipV4BindWsPort: '$P2P_ipV4BindWsPort'
      P2P_ipV6BindAddress: '::'
      P2P_ipV6BindTcpPort: '$P2P_ipV6BindTcpPort'
      P2P_ipV6BindWsPort: '$P2P_ipV6BindWsPort'
      P2P_ANNOUNCE_ADDRESSES: '$P2P_ANNOUNCE_ADDRESSES'
      P2P_FILTER_ANNOUNCED_ADDRESSES: '["127.0.0.0/8","10.0.0.0/8","172.16.0.0/12","192.168.0.0/16"]'
    networks:
      - ocean_network
    depends_on:
      - typesense

  typesense:
    image: typesense/typesense:26.0
    container_name: typesense-$i
    ports:
      - "$Typesense_Port:$Typesense_Port"
    networks:
      - ocean_network
    volumes:
      - typesense-data-$i:/data
    command: '--data-dir /data --api-key=xyz  --api-port $Typesense_Port'

volumes:
  typesense-data-$i:
    driver: local

networks:
  ocean_network:
    driver: bridge
EOF

    echo "docker-compose.yml created in $folder_name"
    docker compose up -d
    cd ..
  done
}

# Input jumlah folder yang ingin dibuat
read -p "Enter the number of folders to create: " num_folders
read -p "Number starts from: " starts_from
create_folders_and_compose "$num_folders" "$starts_from"
