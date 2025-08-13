#!/bin/bash
# Test script for client interaction

(
echo "send Hello from test client"
sleep 1
echo "send Second message"
sleep 1
echo "quit"
) | ./secure_client "$1" "$2"