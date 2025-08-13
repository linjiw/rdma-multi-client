#!/bin/bash

echo "Testing RDMA connection..."
(
    echo "send Hello from test script"
    sleep 1
    echo "send Second message"
    sleep 1
    echo "quit"
) | ./build/secure_client 172.31.34.15 localhost