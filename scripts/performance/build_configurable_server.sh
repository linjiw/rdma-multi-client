#!/bin/bash

# Build RDMA server with configurable MAX_CLIENTS

MAX_CLIENTS=${1:-10}
OUTPUT_NAME=${2:-"secure_server_${MAX_CLIENTS}"}

echo "Building RDMA server with MAX_CLIENTS=$MAX_CLIENTS"

# Create temporary source file
cp src/secure_rdma_server.c src/secure_rdma_server_temp.c

# Update MAX_CLIENTS
sed -i "s/#define MAX_CLIENTS.*/#define MAX_CLIENTS $MAX_CLIENTS/" src/secure_rdma_server_temp.c

# Compile
gcc -Wall -O2 -g -D_GNU_SOURCE -I./src \
    -o "build/${OUTPUT_NAME}" \
    src/secure_rdma_server_temp.c src/tls_utils.c \
    -lrdmacm -libverbs -lpthread -lssl -lcrypto

if [ $? -eq 0 ]; then
    echo "Successfully built: build/${OUTPUT_NAME}"
    echo "  Max clients: $MAX_CLIENTS"
else
    echo "Build failed!"
    exit 1
fi

# Clean up temp file
rm -f src/secure_rdma_server_temp.c